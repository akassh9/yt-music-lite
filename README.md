# YT Music (lite)

A ~370 KB native macOS wrapper for music.youtube.com. It's one AppKit window with one `WKWebView`, using the
WebKit that ships with macOS. There's no Electron, no bundled Chromium, no Node, and no plugin runtime.

## Build

```bash
./build.sh            # -> build/YT Music.app
./build.sh --install  # also copies it to /Applications
```

You only need the Xcode Command Line Tools. The build is arm64-only (Apple silicon).

## What it does to stay light

- **System WebKit** is shared with Safari, so the app process itself stays around 25 MB. Nearly all memory is
  YouTube Music's own page (~400 MB in the WebContent process).
- **Closing the window (⌘W) hides it.** Playback continues, and WebKit stops rendering the page entirely.
- **Hibernation:** with the window closed and nothing playing for 30 minutes, the web view is destroyed and its
  ~400 MB process exits. Clicking the Dock icon (or Play in the Dock menu) rebuilds the page where you left off.
  To change the timeout or turn it off:
  `defaults write local.ytmusic.lite hibernateMinutes -int 60` (`0` disables).
- **Auto-reload for long sessions:** YouTube Music's page can grow over hours of listening. While the window is
  closed and music is playing, the app checks the page's memory every 5 minutes. Past 800 MB, it rebuilds the page
  in a fresh process at the next song change, continuing the same track and playlist (expect a gap of a couple
  of seconds). To change the limit or turn it off:
  `defaults write local.ytmusic.lite recycleAboveMB -int 1000` (`0` disables).
- **Blocks telemetry/ad endpoints** (DoubleClick, Google Analytics, YouTube QoE/ad-tracking pings).
- **Removes CSS backdrop blur**, which otherwise gets re-composited on every scroll frame.

## Features

- Media keys, Control Center, and Now Playing work through WebKit's built-in Media Session support.
- Dock menu: Play/Pause, Next, Previous.
- Playback menu: Play/Pause ⌘P, Next ⌥⌘→, Previous ⌥⌘←.
- Navigation: Back ⌘[, Forward ⌘], Reload ⌘R, Home ⇧⌘H, Zoom ⌘= / ⌘- / ⌘0.
- Automatically dismisses the "Are you still listening?" prompt.
- Links outside YouTube Music open in your default browser.

## Notes

- Sign in once inside the app. Cookies live in the app's own WebKit store (keyed by the bundle ID
  `local.ytmusic.lite`, so don't change it or you'll be signed out).
- With Premium, set **Settings → Playback → Audio quality → High** (256 kbps).
- Songs (audio + artwork) are cheaper than music videos, which still get decoded while the window is hidden.
- After an auto-reload, a shuffled queue continues in playlist order, and a radio mix is regenerated from the
  current song.
