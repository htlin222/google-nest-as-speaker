# App Store tasks

Paused by the owner on 2026-11-03: distribute through GitHub with YouTube and
Bilibili retained. Unfinished items below are deferred, not active blockers.

- [x] Inspect Xcode/signing environment — Xcode 26.6, development identity only.
- [x] Open App Store Connect with ego-lite — sign-in shown; TaskSpace 5 handed off.
- [x] Resolve current distribution direction — owner chose GitHub; Apple login and Store edition choice deferred.
- [x] Prepare production-UI mock capture pipeline and bilingual README drafts.
- [x] Publish reviewed README/screenshots to GitHub — commit d288dbb; relative links, 9 Swift tests and release compilation verified.
- [ ] Verify Apple account, program membership, team role, agreements, app record.
- [ ] Confirm edition scope, price, territory, contact and legal declarations.
- [ ] Implement and test sandbox-compatible, self-contained distribution.
  - [x] Generate Xcode project, nested helper app, sandbox entitlements and signing scripts.
  - [x] Implement lazy file bookmarks and native byte-range serving.
  - [x] Add native audio export/cache; avoid child-process file-grant assumptions.
  - [x] Verify development Release archive and actual sandboxed silent probe.
  - [x] Exclude unused runtime build/tagging packages; retest packaged YouTube/Bilibili/phone IPC.
  - [x] Package dependency inventory, full notices, pinned zeroconf/certifi sources and runtime license provenance.
  - [x] Add per-bundle API-reason manifests and signed-artifact dependency/path checks.
  - [x] Pin and test CPython 3.12.16/OpenSSL 3.5.9/Expat 2.9.0 with isolated packaging bootstrap.
  - [x] Verify actual sandboxed LAN discovery and synthetic Cast PLAYING → FINISHED; preserve receiver volume.
  - [x] Fix low-rate AAC decode failure with bounded 48 kHz normalization; cover existing M4A and CAF inputs.
  - [x] Connect writer-finalization cancellation and rebuild zero-byte cache entries; regression tests pass.
  - [ ] Complete final source/relink/distribution review.
  - [ ] Complete selected-file/restart/SMB/Cast acceptance, format and licensing audit.
  - [ ] Resolve Store website scope and distribution signing/export.
- [ ] Archive/sign/upload; complete accurate App Store metadata and screenshots.
- [ ] Submit and verify actual Waiting for Review state.
