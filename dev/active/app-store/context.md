# App Store context — 2026-11-03

Goal was explicitly created in the current conversation: submit Nest Player and
reach Waiting for Review. It remains active and is not achieved.

Ego-lite TaskSpace 5, p1 is https://appstoreconnect.apple.com/. A sign-in form was
observed and the task was handed to the account holder. Do not resume browser
control until the user confirms login. No password/MFA was requested in chat.

Local tools: Xcode 26.6 (17F113), Swift 6.3.3, xcodegen installed. Keychain check
found one Apple Development identity, no distribution identity. Paid-program
membership/team and App Store Connect permissions are not yet verified.

Engineering progress: XcodeGen 2.46 target, signed nested NestCastService.app
(console IPC with PyInstaller BUNDLE layout), parent sandbox and child inheritance
entitlements. Sign before copying resources; post-build signing broke incremental
resource seals and was removed. Entry: scripts/build_store.sh. Initial target:
arm64, macOS 14+, version 0.2.0 build 3. A development Release archive exists at
.build/NestPlayer-20261103-115009.xcarchive (ignored, not exported/uploaded;
includes the cache-pruning/invalidation fixes).

FileAccessStore persists scoped bookmarks, resolves lazily, maps relocated
folders and retains offline grants. The APP_STORE local-media path now uses
NativeMediaPreparer (AVFoundation audio-only export and completed-output cache)
and NativeMediaServer (one opaque path, bounded clients/headers/chunks and
GET/HEAD/Range). Python receives only HTTP and selects the Cast-facing NIC.
Community website extraction/FFmpeg remain available; no edition decision applied.

Verified: 19 Swift + 27 Python tests, including the added eviction regression check,
community Release compilation, archive deep/strict signature, exact child
sandbox+inherit entitlements, actual sandbox --service-smoke (~2 seconds), and
fresh community helper IPC/phone smoke. Low-budget eviction testing caught
current-file deletion due to URL structural equality and stale URL resource
metadata preventing invalidation. Fixes use normalized paths and fresh filesystem
attributes; the regression test now passes. Probe checks IPC, phone HTTP, synthetic silent CAF
export/cache and native byte ranges; no discovery, Cast audio or volume changes.
Real selected-file/restart/SMB/physical-Cast acceptance is still pending.
See docs/app-store/building.md for commands and limits.

Existing v0.2.0 bundle is ad-hoc signed, unsandboxed, SwiftPM-built, and uses
external FFmpeg/Deno or Node. It is not an App Store uploadable build. Browser
cookie access and third-party website media extraction need explicit scope and
authorization decisions. Selected-file grants are now held by the native process;
actual selected-file/restart behavior still needs acceptance testing.

Documentation captures: Playwright 1.51 with installed Chrome, fresh temporary
contexts; loopback fixture server on 8992; production remote HTML. Native memory
render shows only the actual playback panel with DEBUG-only fictional model;
sidebar controls are excluded. Full-window screencapture was denied by macOS.
These GitHub artwork assets are not final App Store screenshot evidence.

Source: https://developer.apple.com/app-store/review/guidelines/ (2.3 screenshots,
2.4.5 Mac packaging/sandbox, 2.5.2 bundle/code, 5.2.2/5.2.3 media authorization).
