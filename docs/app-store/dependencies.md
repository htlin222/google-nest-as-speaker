# Frozen dependency inventory and notices

This records packaging evidence, not final legal or App Store clearance.
The final edition, license obligations and distribution terms remain under review.

## What the build includes

`scripts/collect_bundle_notices.py` inspects the frozen Python module archive and
matches modules to installed distribution records. It does not treat every
development dependency as shipped code. Each frozen helper contains:

- `ThirdPartyNotices.txt`: complete license/notice texts for identified runtime
  packages, the PyInstaller bootloader and CPython/native runtime components.
- `DependencyInventory.json`: versions, upstream license metadata, module counts,
  source references and remaining review items. This is a project-specific
  inventory format, not a certified SPDX/CycloneDX SBOM.
- `ThirdPartySources/`: the unmodified zeroconf and certifi source archives from
  `uv.lock`, with download sizes and SHA-256 checked before packaging.
- `RuntimeNotices/`: 13 runtime license texts and a provenance/hash manifest.

For the sandbox helper these files are under
`Contents/Helpers/NestCastService.app/Contents/Resources/` inside the main app.
For a community helper they are alongside `nest-service`.

| Component | Version observed | Upstream license metadata |
| --- | --- | --- |
| PyChromecast | 14.1.0 | MIT |
| zeroconf | 0.153.0 | LGPL-2.1-or-later |
| ifaddr | 0.2.0 | MIT |
| protobuf | 7.36.2 | BSD 3-Clause |
| yt-dlp | 2026.10.26 | Unlicense |
| yt-dlp-ejs | 0.8.0 | Unlicense AND MIT AND ISC |
| requests | 2.34.2 | Apache-2.0 |
| urllib3 | 2.8.0 | MIT |
| certifi | 2026.10.23 | MPL-2.0 |
| charset-normalizer | 3.5.2 | MIT |
| idna | 3.20 | BSD-3-Clause |
| websockets | 17.4 | BSD-3-Clause |
| Brotli | 1.2.1 | MIT |
| pycryptodomex | 3.24.1 | BSD / Public Domain |
| PyInstaller bootloader | 6.22.0 | GPL with its bundled distribution exception |

The full included texts take precedence over this short metadata table.
zeroconf and certifi need explicit distribution review; bundling source and
notices is evidence toward that review, not a claim that all obligations or
Store terms have been resolved.

## Excluded code and verification

Mutagen's optional file-tagging postprocessors and the PyInstaller/setuptools/
pkg_resources build packages are excluded from frozen runtime imports. The
PyInstaller bootloader remains and retains its notice. The CLI's locked
development environment still contains optional dependencies.

Observed comparison before notices were added: 1,803 to 1,543 frozen modules and
49,411,609 to 47,270,900 file bytes (about 2 MiB smaller). Public YouTube and
Bilibili extraction still returned audio/video streams; phone IPC passed. These
are packaging observations, not measured CPU/RAM or cold-start improvements.

`scripts/verify_store_bundle.py` checks deep/strict signatures, matching signing
teams, parent and helper entitlements, API-reason manifests, no escaping symlinks,
and Mach-O load commands/rpaths without external build-machine/private framework
dependencies. It also verifies the module inventory, bundled source hashes and
native-runtime notice profile. It does not replace Apple's export/upload checks.

## Native runtime provenance

The current engineering build uses CPython 3.12.11 from the upstream
[20250818 python-build-standalone release](https://github.com/astral-sh/python-build-standalone/releases/tag/20250818).
The full archive hash was checked against the release digest, and its libpython
Mach-O UUID matched the installed stripped runtime. The upstream build metadata
identified applicable license texts for built-in native modules, including
OpenSSL, compression, XML, SQLite, libffi and related runtime components.
[`manifest.json`](../../AppStore/RuntimeLicenses/manifest.json) records the source,
binary identity and per-file hashes. The runtime/security patch baseline still
needs updating or explicit qualification before commercial release.

To refresh the profile for a different interpreter, obtain that exact upstream
full archive, verify its published digest, then run with the build interpreter:

```bash
uv run --locked python scripts/import_runtime_notices.py /path/to/full.tar.zst \
  --sha256 VERIFIED_RELEASE_DIGEST --source-url VERIFIED_UPSTREAM_ASSET_URL
```

The tool refuses a mismatched interpreter version or Mach-O UUID. A Store build
without a matching native-runtime notice profile fails its packaging check.

## Rebuilding with a modified dependency

Source and build scripts are available in this repository. For a personal
rebuild, unpack the verified corresponding-source archive into a working
directory, edit it, and point a checkout at the modified source:

```bash
uv add /absolute/path/to/modified/zeroconf-0.153.0
bash scripts/build_app.sh
```

`uv add` updates that checkout's source dependency and lockfile; use a regular
local source build so the frozen inventory can identify its installed files.
This produces a community `.app` signed locally. The sandbox engineering build
can instead be rebuilt with the developer's signing configuration as described
in [building.md](building.md).

When the modified dependency comes from a local source rather than a registry
sdist, the inventory explicitly flags that its modified corresponding source
needs packaging before redistribution. Final redistribution terms, source
access and any applicable relinking requirements need review for the actual
edition and delivery channel.

Upstream references: [zeroconf source](https://github.com/python-zeroconf/python-zeroconf),
[certifi source](https://github.com/certifi/python-certifi),
[PyInstaller license](https://github.com/pyinstaller/pyinstaller/blob/v6.22.0/COPYING.txt),
[python-build-standalone licensing](https://gregoryszorc.com/docs/python-build-standalone/main/running.html#licensing).
