# Reproducing the screenshots

These are real rendered product views using fictional media and device data.
They are documentation assets for the GitHub edition, not a claim of App Store
approval or final App Store submission screenshots.

- `native-player.png`: the playback panel from the production SwiftUI ContentView, rendered by AppKit
  with an isolated DEBUG-only mock PlayerModel. No Cast service or user playlist
  is loaded; this is not a browser recreation of the native app. The sidebar is
  deliberately excluded because its layer-backed controls do not render in this
  memory snapshot. A full-window capture requires macOS screen-recording consent.
- `iphone-remote.png` and `phone-pairing.png`: the production remote HTML,
  rendered by Playwright at 390 × 844 with a mock API, in a fresh Chrome context.
- `feature-overview.png`: a Playwright-captured HTML composition of those real
  UI captures with editorial labels. The phone frame is a presentation device.

No live pair token, network address, browser account, or private media is used.
The preview server binds only to loopback and cannot send Cast commands.

## Capture

Requirements: macOS, Swift, uv, Node, Playwright (`npm install -g playwright`),
and Google Chrome. A different installed Chromium channel can be selected with
`PLAYWRIGHT_CHANNEL`.

```bash
mkdir -p .build assets/screenshots
swiftc -D DEBUG -parse-as-library -o .build/render-native-preview \
  Sources/NestPlayer/CastBackend.swift Sources/NestPlayer/CastModels.swift \
  Sources/NestPlayer/ContentView.swift Sources/NestPlayer/MediaSources.swift \
  Sources/NestPlayer/PlayerLayerView.swift Sources/NestPlayer/PlayerModel.swift \
  Sources/NestPlayer/SourceSheets.swift scripts/render_native_preview.swift
.build/render-native-preview assets/screenshots/native-player.png
uv run python scripts/preview_server.py
```

In another terminal:

```bash
node scripts/capture_screenshots.mjs
```

`capture.json` records how the images were made. Inspect the output visually
before committing it; images should show the current production interface.
