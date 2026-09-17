# StopAndGo integration

This branch adds a native StopAndGo client to IINA. It uses IINA's built-in
libmpv engine; the separate mpv app and StopAndGo Lua scripts are not required.

The integration is enabled when `$XDG_CONFIG_HOME/stopandgo/stopandgo.conf`
exists (normally `~/.config/stopandgo/stopandgo.conf`). The companion
`clip-last.conf` configures server exports. The formats and keys match the
StopAndGo project's configuration examples. Restart IINA after editing them.
The StopAndGo project's `macos/install-iina-client.sh` migrates existing settings.

Opening the configured fork shows the library. Ctrl+B toggles the library during
playback; up/down selects, Return or double-click plays, Tab/C switches movies
and clips, R reloads, and Escape closes. The native table also supports page
navigation. The last selection is retained for each tab.

The IINA Library launcher sends `iina://stopandgo` to the fork so it opens the
picker even while a movie is playing. Clicking the fork's Dock icon also brings
up the picker, and File → StopAndGo Library opens it from inside IINA.

During playback, 5 exports the preceding 15 seconds on the server and S uploads
a PNG of the current frame including subtitles. Keys, clip duration, endpoints,
tokens and request timeouts are configurable. Clip jobs are polled until
complete, failed, or five minutes of polling have elapsed. Results appear in
IINA's OSD and in the library status text. Completed exports remain available
in the existing StopAndGo web gallery.

The unmodified right-arrow key is ignored in player windows. Timeline clicking,
rewinding, and text-field navigation retain their normal behavior.

## Build and install

Use full Xcode and the build steps in README.md, or run the **Build StopAndGo
IINA** GitHub Actions workflow on this branch. Its artifact is a universal,
ad-hoc signed app, not an Apple-notarized distribution. The bundle contains
`StopAndGoIntegrationVersion=1` so the installer can reject an upstream build
that lacks this functionality. Automatic upstream update checks default to off;
install updates from this fork to retain the integration.

From the StopAndGo repository, install the extracted build with:

```sh
./macos/install-iina-client.sh /absolute/path/to/IINA.app
```

## Verification before retiring the old player

1. Launch IINA Library with the migrated config; confirm movie metadata loads.
2. Play a movie, seek using the timeline, and confirm Right does not advance it.
3. Use Ctrl+B, Tab/C, R and Escape; play a completed clip and return to movies.
4. After at least 15 seconds, press 5 and verify the completed clip in the gallery.
5. With visible subtitles, press S and verify the uploaded PNG includes them.
6. Verify authenticated requests if a token is configured; test a failed request
   and a library retry. Confirm reopening IINA with no windows shows the library.

Do not remove the old mpv installation until these checks pass on the built fork.
