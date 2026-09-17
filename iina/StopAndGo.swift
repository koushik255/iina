import Cocoa

/// Native client for the StopAndGo server. No standalone mpv application or Lua scripts are needed.
final class StopAndGo: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
  static let shared = StopAndGo()

  struct Settings {
    let library: [String: String]
    let exports: [String: String]
    let enabled: Bool

    static func read(_ url: URL) -> [String: String] {
      guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
      var values: [String: String] = [:]
      for line in text.components(separatedBy: .newlines) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("#"), let separator = trimmed.firstIndex(of: "=") else { continue }
        values[String(trimmed[..<separator]).trimmingCharacters(in: .whitespaces)] =
          String(trimmed[trimmed.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
      }
      return values
    }

    init() {
      let root = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] ??
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config").path
      let directory = URL(fileURLWithPath: root).appendingPathComponent("stopandgo")
      library = Self.read(directory.appendingPathComponent("stopandgo.conf"))
      exports = Self.read(directory.appendingPathComponent("clip-last.conf"))
      enabled = !library.isEmpty
    }

    var api: URL? { URL(string: library["api_url"] ?? "http://127.0.0.1:8765/api/files") }
    var clips: URL? {
      if let explicit = library["clips_api_url"], !explicit.isEmpty { return URL(string: explicit) }
      return api?.deletingLastPathComponent().appendingPathComponent("clips")
    }
    var server: URL? {
      if let explicit = exports["server_url"], !explicit.isEmpty { return URL(string: explicit) }
      return api?.deletingLastPathComponent().deletingLastPathComponent()
    }
    var libraryKey: String { library["key"] ?? "Ctrl+b" }
    var clipKey: String { exports["clip_key"] ?? "5" }
    var screenshotKey: String { exports["screenshot_key"] ?? "s" }
    var seconds: Double { max(1, Double(exports["seconds"] ?? "15") ?? 15) }
  }

  struct Item: Decodable {
    let name: String
    let title: String?
    let year: String?
    let url: URL
    let size: Int64
    let duration: Double?
    let width: Int?
    let height: Int?
    let video_codec: String?
    let created: String?

    var displayTitle: String {
      (title ?? name) + (year.map { "  (\($0))" } ?? "")
    }
    var details: String {
      var parts: [String] = []
      if let created { parts.append(created) }
      if let duration, duration > 0 { parts.append("\(Int(duration / 60))m") }
      if let height, height > 0 { parts.append("\(height)p") }
      if let video_codec { parts.append(video_codec) }
      parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .binary))
      return parts.joined(separator: "   ")
    }
  }
  struct Catalog: Decodable { let files: [Item]; let hidden: Int? }
  struct Export: Decodable {
    let id: String?
    let status: String?
    let error: String?
    let server_path: String?
  }
  struct RequestFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }

  private let settings = Settings()
  private let table = NSTableView()
  private let status = NSTextField(wrappingLabelWithString: "")
  private let tabs = NSSegmentedControl(labels: ["Movies", "Clips"], trackingMode: .selectOne,
                                        target: nil, action: nil)
  private var items: [Item] = []
  private var selections = [0, 0]
  private var selectedTab = 0
  private var catalogTask: URLSessionDataTask?
  private var generation = 0
  private var keyMonitor: Any?
  private weak var playbackPlayer: PlayerCore?

  private init() { super.init(window: nil) }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func install() {
    guard settings.enabled, keyMonitor == nil else { return }
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self else { return event }
      return self.handleKey(event) ? nil : event
    }
    let item = NSMenuItem(title: "StopAndGo Library…", action: #selector(showLibrary), keyEquivalent: "")
    item.target = self
    AppDelegate.shared.menuController?.fileMenu?.addItem(item)
  }

  var isEnabled: Bool { settings.enabled }

  @objc func showLibrary() {
    if window == nil { buildWindow() }
    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
    window?.makeFirstResponder(table)
    refresh()
  }

  private func buildWindow() {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 520),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
    window.title = "StopAndGo Library"
    window.isReleasedWhenClosed = false
    window.minSize = NSSize(width: 600, height: 320)
    window.center()
    self.window = window
    tabs.selectedSegment = 0
    tabs.target = self
    tabs.action = #selector(switchLibrary)
    let reload = NSButton(title: "Reload", target: self, action: #selector(refresh))
    let play = NSButton(title: "Play", target: self, action: #selector(playSelected))
    let controls = NSStackView(views: [tabs, reload, play])
    controls.spacing = 12
    for (id, title, width) in [("title", "Title", 440.0), ("details", "Details", 390.0)] {
      let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
      column.title = title
      column.width = width
      table.addTableColumn(column)
    }
    table.delegate = self
    table.dataSource = self
    table.rowHeight = 36
    table.usesAlternatingRowBackgroundColors = true
    table.target = self
    table.doubleAction = #selector(playSelected)
    let scroll = NSScrollView()
    scroll.documentView = table
    scroll.hasVerticalScroller = true
    let help = NSTextField(labelWithString: "↑/↓ select   Return play   Tab switch   R reload   Esc close")
    help.textColor = .secondaryLabelColor
    let content = NSStackView(views: [controls, scroll, status, help])
    content.orientation = .vertical
    content.alignment = .leading
    content.spacing = 12
    content.translatesAutoresizingMaskIntoConstraints = false
    window.contentView!.addSubview(content)
    NSLayoutConstraint.activate([
      content.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 20),
      content.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -20),
      content.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 20),
      content.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -20),
      scroll.widthAnchor.constraint(equalTo: content.widthAnchor),
      status.widthAnchor.constraint(equalTo: content.widthAnchor),
    ])
  }

  func numberOfRows(in tableView: NSTableView) -> Int { items.count }
  func tableViewSelectionDidChange(_ notification: Notification) {
    if items.indices.contains(table.selectedRow) { selections[selectedTab] = table.selectedRow }
  }
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    let text = tableColumn?.identifier.rawValue == "title" ? items[row].displayTitle : items[row].details
    let label = NSTextField(labelWithString: text)
    label.lineBreakMode = .byTruncatingTail
    label.toolTip = text
    return label
  }

  @objc private func switchLibrary() {
    selections[selectedTab] = max(0, table.selectedRow)
    selectedTab = tabs.selectedSegment
    refresh()
  }

  @objc private func refresh() {
    generation += 1
    let requestGeneration = generation
    catalogTask?.cancel()
    items = []
    table.reloadData()
    status.stringValue = "Scanning…"
    catalogTask = request(selectedTab == 0 ? settings.api : settings.clips, exports: false) {
      [weak self] (result: Result<Catalog, Error>) in
      guard let self, self.generation == requestGeneration else { return }
      switch result {
      case .failure(let error): self.status.stringValue = "Could not load library: \(error.localizedDescription)"
      case .success(let catalog):
        self.items = catalog.files
        self.table.reloadData()
        if !self.items.isEmpty {
          let row = min(self.selections[self.selectedTab], self.items.count - 1)
          self.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
          self.table.scrollRowToVisible(row)
        }
        self.status.stringValue = "\(self.items.count) \(self.selectedTab == 0 ? "movies" : "clips") • \(catalog.hidden ?? 0) skipped"
      }
    }
  }

  @objc private func playSelected() {
    guard items.indices.contains(table.selectedRow) else { return }
    let item = items[table.selectedRow]
    selections[selectedTab] = table.selectedRow
    let player = playbackPlayer ?? PlayerCore.activeOrNew
    playbackPlayer = player
    player.openURL(item.url, shouldAutoLoad: false)
    close()
  }

  private func handleKey(_ event: NSEvent) -> Bool {
    // Preserve normal editing/navigation in IINA's search and URL fields.
    if let editor = event.window?.firstResponder as? NSTextView, editor.isEditable { return false }
    let key = KeyCodeHelper.normalizeMpv(KeyCodeHelper.mpvKeyCode(from: event))
    if key == KeyCodeHelper.normalizeMpv(settings.libraryKey) {
      if !event.isARepeat {
        playbackPlayer = (event.window?.windowController as? PlayerWindowController)?.player ?? playbackPlayer
        if window?.isKeyWindow == true { close() } else { showLibrary() }
      }
      return true
    }
    if let window, event.window === window {
      switch key {
      case "TAB", "c":
        tabs.selectedSegment = 1 - selectedTab
        switchLibrary()
      case "r": refresh()
      case "ENTER", "KP_ENTER": playSelected()
      case "ESC": close()
      default: return false
      }
      return true
    }
    guard let player = (event.window?.windowController as? PlayerWindowController)?.player else { return false }
    if key == "RIGHT" { return true }
    if key == KeyCodeHelper.normalizeMpv(settings.clipKey) {
      if !event.isARepeat { saveClip(player) }
      return true
    }
    if key == KeyCodeHelper.normalizeMpv(settings.screenshotKey) {
      if !event.isARepeat { saveScreenshot(player) }
      return true
    }
    return false
  }

  private func source(_ player: PlayerCore) -> String? {
    guard let raw = player.mpv.getString("path"), let url = URL(string: raw),
          let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          let range = components.percentEncodedPath.range(of: "/media/") else { return nil }
    return String(components.percentEncodedPath[range.upperBound...]).removingPercentEncoding
  }

  private func report(_ message: String, to player: PlayerCore) {
    status.stringValue = message
    player.sendOSD(.custom(message), forcedTimeout: 4)
  }

  private func saveClip(_ player: PlayerCore) {
    guard let path = source(player) else {
      report("Server clips only work on StopAndGo movies", to: player)
      return
    }
    let position = player.mpv.getDouble("time-pos")
    let payload: [String: Any] = ["path": path, "end": position, "duration": settings.seconds]
    guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
    report("Creating \(Int(settings.seconds))s clip on server…", to: player)
    request(settings.server?.appendingPathComponent("api/export/clip"), body: data,
            contentType: "application/json") { [weak self] (result: Result<Export, Error>) in
      guard let self else { return }
      switch result {
      case .failure(let error): self.report("Clip failed: \(error.localizedDescription)", to: player)
      case .success(let response):
        guard let id = response.id else {
          self.report("Clip failed: missing job ID", to: player)
          return
        }
        self.pollClip(id, player: player, remaining: 300)
      }
    }
  }

  private func pollClip(_ id: String, player: PlayerCore, remaining: Int) {
    guard remaining > 0 else { report("Clip still running on server", to: player); return }
    request(settings.server?.appendingPathComponent("api/export/jobs").appendingPathComponent(id)) {
      [weak self] (result: Result<Export, Error>) in
      guard let self else { return }
      switch result {
      case .failure(let error): self.report("Clip status failed: \(error.localizedDescription)", to: player)
      case .success(let job):
        switch job.status {
        case "complete": self.report("Clip saved on server: \(job.server_path ?? "")", to: player)
        case "failed": self.report("Clip failed: \(job.error ?? "unknown error")", to: player)
        default:
          DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            self.pollClip(id, player: player, remaining: remaining - 1)
          }
        }
      }
    }
  }

  private func saveScreenshot(_ player: PlayerCore) {
    guard let path = source(player), let server = settings.server else {
      report("Server screenshots only work on StopAndGo movies", to: player)
      return
    }
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("stopandgo-\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: temporary) }
    var screenshotResult: Int32 = -1
    player.mpv.command(.screenshotToFile, args: [temporary.path, "subtitles"], checkError: false,
                       returnValueCallback: { screenshotResult = $0 })
    guard screenshotResult >= 0, let png = try? Data(contentsOf: temporary) else {
      report("Screenshot capture failed", to: player)
      return
    }
    var url = URLComponents(url: server.appendingPathComponent("api/export/screenshot"), resolvingAgainstBaseURL: false)
    url?.queryItems = [URLQueryItem(name: "path", value: path)]
    report("Uploading screenshot…", to: player)
    request(url?.url, body: png, contentType: "image/png") { [weak self] (result: Result<Export, Error>) in
      switch result {
      case .success(let response): self?.report("Screenshot saved on server: \(response.server_path ?? "")", to: player)
      case .failure(let error): self?.report("Screenshot upload failed: \(error.localizedDescription)", to: player)
      }
    }
  }

  @discardableResult
  private func request<T: Decodable>(_ url: URL?, exports: Bool = true, body: Data? = nil,
                                     contentType: String? = nil,
                                     completion: @escaping (Result<T, Error>) -> Void) -> URLSessionDataTask? {
    guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
      completion(.failure(RequestFailure(message: "Configure a valid HTTP(S) server URL in ~/.config/stopandgo.")))
      return nil
    }
    let values = exports ? settings.exports : settings.library
    var request = URLRequest(url: url)
    request.timeoutInterval = max(1, Double(values["timeout"] ?? "30") ?? 30)
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let token = values["token"] ?? settings.library["token"] ?? ""
    if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    if let body {
      request.httpMethod = "POST"
      request.httpBody = body
      request.setValue(contentType, forHTTPHeaderField: "Content-Type")
    }
    let task = URLSession.shared.dataTask(with: request) { data, response, error in
      let result: Result<T, Error>
      if let error { result = .failure(error) }
      else if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
        result = .failure(RequestFailure(message: "Server returned HTTP \(http.statusCode)"))
      } else {
        result = Result { try JSONDecoder().decode(T.self, from: data ?? Data()) }
      }
      DispatchQueue.main.async { completion(result) }
    }
    task.resume()
    return task
  }
}
