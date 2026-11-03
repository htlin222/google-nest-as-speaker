# Mac App Store readiness

Status: preparation in progress; not submitted. Updated 2026-11-03.

The v0.2.0 GitHub application is an ad-hoc-signed community distribution. It is
not a Mac App Store archive and should not be uploaded as though it were one.

| Area | Observed state | Required next step |
| --- | --- | --- |
| App Store Connect | Sign-in form; account holder handoff pending | Authenticate and verify team permissions/membership |
| Signing | Apple Development identity only | Configure the appropriate distribution signing and provisioning |
| Packaging | Xcode project and signed development Release archive verified | Configure and validate distribution export/upload |
| Sandbox | Native bookmarks/file serving; parent sandbox and inheriting helper verified | Complete selected-file/restart/SMB/Cast acceptance |
| Media tools | Engineering Store local-media path uses AVFoundation and a cache | Finish format/license audit; website JS runtime unresolved |
| Website media | yt-dlp extraction and explicit browser-cookie opt-in | Confirm authorization and Store edition scope; do not conceal functionality |
| Store assets | GitHub demo artwork available | Capture the actual submitted edition and complete accurate localizations |
| Commercial setup | Price, territories and agreements unconfirmed | Account holder chooses and completes required declarations |

Apple's [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
require sandboxed, self-contained Mac distribution (2.4.5/2.5.2), accurate app-in-use
screenshots (2.3), and appropriate authorization for third-party media access
(5.2.2/5.2.3). Streaming through a local proxy does not itself establish that
authorization. This is an engineering review plan, not a promise of approval.

## Proposed first commercial edition

Pending user approval: local files and user-mounted SMB folders, playlists,
local video with Cast audio, and the paired iPhone browser remote. Website
extraction can remain in the GitHub edition while authorization and technical
requirements are resolved. The existing GitHub features are unchanged.

## Engineering direction for review

The [sandboxed engineering target](building.md) keeps selected-file reads and
audio preparation in the native process. The persistent Cast helper receives
an opaque HTTP capability. The actual sandboxed app passes a silent service,
HTTP, export, cache and range probe. A development Release archive passes
signature verification, without `get-task-allow` in its application entitlements.
This is not a distribution export or complete end-to-end acceptance test.
Dependency licensing, website scope, physical playback and selected-file access
still need completion.

No account contract, paid enrollment, final price, export declaration, privacy
declaration, or submission has been accepted or invented by the agent.
