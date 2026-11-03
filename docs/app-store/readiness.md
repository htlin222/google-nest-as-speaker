# Mac App Store readiness

Status: preparation in progress; not submitted. Updated 2026-11-03.

The v0.2.0 GitHub application is an ad-hoc-signed community distribution. It is
not a Mac App Store archive and should not be uploaded as though it were one.

| Area | Observed state | Required next step |
| --- | --- | --- |
| App Store Connect | Sign-in form; account holder handoff pending | Authenticate and verify team permissions/membership |
| Signing | Apple Development identity only | Configure the appropriate distribution signing and provisioning |
| Packaging | SwiftPM executable + frozen helper, ad-hoc bundle | Create and validate an Xcode archive/export path |
| Sandbox | No runtime sandbox entitlements | Implement file/folder bookmarks, permission lifetime, helper access, and LAN entitlements |
| Media tools | FFmpeg and JS runtime are external dependencies | Use self-contained, licensed components or platform APIs |
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

Use native macOS APIs for persistent user-selected file permissions and, where
possible, audio export. A sandboxed helper cannot be assumed to inherit a file
permission granted after the helper started; native file serving or an explicit
capability/file-descriptor handoff must be tested. All shipped executable tools
and libraries need a consistent signing and licensing strategy. Avoid a runtime
package installer, unsigned nested code, and reliance on Homebrew for Store use.

No account contract, paid enrollment, final price, export declaration, privacy
declaration, or submission has been accepted or invented by the agent.
