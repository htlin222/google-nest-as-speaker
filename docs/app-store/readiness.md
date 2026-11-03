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
| Media tools | Native audio/cache and physical synthetic Cast playback verified; low-rate AAC normalized to 48 kHz; pinned Python/OpenSSL/Expat runtime | Finish user-media/format acceptance; website JS runtime unresolved |
| Dependency notices | Frozen inventory, upstream notices, two checked source archives and matching runtime license profile packaged | Complete distribution-terms/source/relink review |
| Privacy | Per-bundle API-use manifests and data-flow inventory prepared | Confirm final edition, public policy and App Store questionnaire |
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
HTTP, export, cache and range probe. Separate opt-in probes verified live speaker
discovery and five seconds of silent playback through PLAYING → FINISHED without
changing volume. An actual low-rate AAC decode failure was fixed by explicit
48 kHz normalization, with regression coverage for CAF and existing M4A input.
A development Release archive passes
signature verification, without `get-task-allow` in its application entitlements.
This is not a distribution export or complete end-to-end acceptance test.
Dependency licensing, website scope, user-media playback and selected-file access
still need completion.

The [dependency record](dependencies.md) now identifies shipped runtime code and
preserves its notices/source materials; it excludes optional tagging and build
packages. [Privacy implementation notes](privacy-review.md) map stored/shared
data and API reasons without inventing final App Store questionnaire answers.

No account contract, paid enrollment, final price, export declaration, privacy
declaration, or submission has been accepted or invented by the agent.
