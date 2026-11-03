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
.build/NestPlayer-20261103-123547.xcarchive (ignored, not exported/uploaded;
includes cache fixes, privacy manifests and dependency/runtime notices).

Latest packaging work excludes unused Mutagen/PyInstaller/setuptools/pkg_resources
runtime modules, preserving the bootloader notice. Fresh packaged helper tested
public YouTube+Bilibili extraction and phone IPC. Module count: 1803 -> 1543;
file bytes before notices: 49,411,609 -> 47,270,900 (~2 MiB), no measured CPU/RAM
claim. collect_bundle_notices.py inspects actual PYZ modules, includes 15 component
notices, and bundles hash-checked zeroconf/certifi sdists from uv.lock. A modified
local library can rebuild; inventory flags modified source packaging as pending.

Runtime now uses CPython 3.12.16/OpenSSL 3.5.9/Expat 2.9.0 from PBS 20261026.
Checked Python security release and OpenSSL maintained branches on 2026-11-03.
AppStore/Runtime.lock.json pins installer/full-archive URLs/digests/sizes and
expected versions. Bootstrap uses .build/runtimes/353d5f1b4fd2715e/python and
.build/packaging-venv; the user's .venv remains on its original 3.12.11.
Upstream full archive is cached in .build/runtime-upgrade; its digest is
016758f4881e5f71d63eddfbcdd53f25c5a9152435a863e4dc0770758eae32c3.
Installed stripped libpython matches the full artifact's Mach-O UUID; 14 matching
runtime license texts/provenance are in AppStore/RuntimeLicenses. Runtime's minimum
macOS is 11.0; the app targets 14.0. Bundle checks reject baseline/profile mismatch.
runtimeInfo IPC returns actual running Python/OpenSSL/Expat versions; both
packaged and native sandbox smoke probes validate them against inventory/lock.
Latest tests: 19 Swift, 27 Python on the new runtime, native sandbox smoke and
fresh community-helper YouTube+Bilibili/phone IPC all pass. The standalone site
probe uses the community helper; sandbox-inheriting helper must be launched by
its signed native parent. scripts/smoke_bundle.py now explains early child exits.

verify_store_bundle.py checks signatures, same signing team, exact helper
inheritance entitlements, reviewed API reason manifests, source/license hashes,
actual runtime UUID/versions/minimum macOS, no escaping symlinks and no external/private load commands
or rpaths. Current Release has 66 Mach-O files, 1543 modules and two verified
source archives. API manifests describe native UserDefaults/file metadata and
helper cache metadata/elapsed timers; final data-use questionnaire is pending.
See docs/app-store/dependencies.md and privacy-review.md. License notices/source
materials are engineering evidence, not full legal/Store clearance.

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
