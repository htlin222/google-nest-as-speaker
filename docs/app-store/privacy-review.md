# Privacy implementation inventory — owner review pending

This is an engineering record, not the final published privacy policy or App
Store Connect privacy questionnaire. Website feature scope, provider data
handling, owner contact details and retention wording still need confirmation.

## Observed data flows

| Data | Current use and storage |
| --- | --- |
| Playlist titles, file paths and website links | Saved in local app preferences for playlist restoration |
| File/folder bookmarks | Saved locally; native process activates access when needed |
| SMB address | Saved locally; Finder handles mounting and credentials |
| Cast names and local addresses | Cached locally for discovery and reconnection |
| Media bytes | Read locally; served over LAN to the selected Cast device |
| Converted audio | Local completed-output cache; active conversion partial removed on cancellation |
| Phone state | Playlist titles, status, speaker name and playback controls sent to the paired LAN browser |
| Phone pairing token/code | Current service token/code in memory; paired browser keeps the token in sessionStorage for its tab session |
| Website requests | Link/provider/CDN traffic goes to the requested service; exact behavior depends on the final edition |
| Browser login session | Community flow reads a chosen browser session only after explicit opt-in; no Nest Player account is created |

No developer-operated analytics, advertising, cloud upload endpoint or account
backend was found in the inspected application code. That observation alone is
not a final App Store privacy answer: the actual submitted edition and its
third-party services must be assessed together. LAN media/control traffic uses
HTTP with capability/pairing tokens; it is not an encrypted Internet relay.

Deleting playlist rows does not currently remove all stored bookmark records.
Cache eviction is automatic, with limits documented in [building.md](building.md).
Exact retention/reset instructions must match the shipping UI and edition.

## API reason manifests

Both manifests are copied to their macOS bundle's `Contents/Resources` before
signing, following [Apple's placement documentation](https://developer.apple.com/documentation/bundleresources/adding-a-privacy-manifest-to-your-app-or-third-party-sdk).

| Bundle | API category | Declared reason and matching implementation |
| --- | --- | --- |
| Native app | UserDefaults | CA92.1 — app-owned playlist, device and bookmark preferences |
| Native app | FileTimestamp | C617.1 — cache metadata; 3B52.1 — explicitly selected file/folder metadata |
| Cast helper | FileTimestamp | C617.1 — its own cache/resource metadata |
| Cast helper | SystemBootTime | 35F9.1 — elapsed-time deadlines, playback monitoring and pairing rate limits |

Reason identifiers were checked against Apple's
[API category reference](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype).
The files describe these API uses; they do not manufacture final collection or
tracking questionnaire answers. Recheck them after the website edition decision
or any change to telemetry, storage, diagnostics or third-party code.

Remaining: final data-use review, public policy/support URLs, owner contact,
retention/reset behavior, third-party website declarations, and the actual App
Store Connect questionnaire/export validation.
