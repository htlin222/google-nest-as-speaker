# App Store context — 2026-11-03

Goal was explicitly created in the current conversation: submit Nest Player and
reach Waiting for Review. It remains active and is not achieved.

Ego-lite TaskSpace 5, p1 is https://appstoreconnect.apple.com/. A sign-in form was
observed and the task was handed to the account holder. Do not resume browser
control until the user confirms login. No password/MFA was requested in chat.

Local tools: Xcode 26.6 (17F113), Swift 6.3.3, xcodegen installed. Keychain check
found one Apple Development identity, no distribution identity. Paid-program
membership/team and App Store Connect permissions are not yet verified.

Existing v0.2.0 bundle is ad-hoc signed, unsandboxed, SwiftPM-built, and uses
external FFmpeg/Deno or Node. It is not an App Store uploadable build. Browser
cookie access and third-party website media extraction need explicit scope and
authorization decisions. Local/SMB security-scoped access must remain valid for
the owning native process and any media helper; saved paths alone are insufficient.

Documentation captures: Playwright 1.51 with installed Chrome, fresh temporary
contexts; loopback fixture server on 8992; production remote HTML. Native memory
render shows only the actual playback panel with DEBUG-only fictional model;
sidebar controls are excluded. Full-window screencapture was denied by macOS.
These GitHub artwork assets are not final App Store screenshot evidence.

Source: https://developer.apple.com/app-store/review/guidelines/ (2.3 screenshots,
2.4.5 Mac packaging/sandbox, 2.5.2 bundle/code, 5.2.2/5.2.3 media authorization).
