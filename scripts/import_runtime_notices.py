#!/usr/bin/env python3
"""Import license texts from the matching python-build-standalone full artifact."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import subprocess
import sys


def uuid(path: Path) -> str:
    return subprocess.check_output(["/usr/bin/dwarfdump", "--uuid", str(path)], text=True).split()[1]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("archive", type=Path)
    parser.add_argument("--sha256", required=True)
    parser.add_argument("--source-url", required=True)
    args = parser.parse_args()
    if hashlib.sha256(args.archive.read_bytes()).hexdigest() != args.sha256:
        raise ValueError("Upstream runtime archive hash does not match")

    def read(member: str) -> bytes:
        parts = PurePosixPath(member).parts
        if not member.startswith("python/") or ".." in parts:
            raise ValueError("Unsafe archive member")
        return subprocess.check_output(["/usr/bin/tar", "-xOf", str(args.archive), "--", member])

    data = json.loads(read("python/PYTHON.json"))
    version = sys.version.split()[0]
    if data["python_version"] != version:
        raise ValueError("Archive and build interpreter versions differ")
    installed = Path(sys.base_prefix) / f"lib/libpython{sys.version_info.major}.{sys.version_info.minor}.dylib"
    # The install-only runtime is stripped. Its byte hash differs from the full
    # archive, but the Mach-O UUID must identify the same linked build.
    temporary = Path(__file__).resolve().parents[1] / ".build/runtime-licensing"
    temporary.mkdir(parents=True, exist_ok=True)
    upstream = temporary / "upstream-libpython.dylib"
    upstream.write_bytes(read("python/install/" + str(installed.relative_to(Path(sys.base_prefix)))))
    if uuid(upstream) != uuid(installed):
        raise ValueError("Runtime Mach-O UUID differs from upstream artifact")
    members = set(subprocess.check_output(["/usr/bin/tar", "-tf", str(args.archive)], text=True).splitlines())
    license_paths = {data["license_path"]}
    for name, configs in data["build_info"]["extensions"].items():
        if name in sys.builtin_module_names:
            for config in configs:
                license_paths.update(config.get("license_paths", []))
    output = Path(__file__).resolve().parents[1] / "AppStore/RuntimeLicenses"
    output.mkdir(exist_ok=True)
    imported = []
    for name in sorted(license_paths):
        member = "python/" + name
        if member not in members:
            continue  # Upstream metadata also names licenses for other platforms.
        if not member.startswith("python/licenses/LICENSE."):
            raise ValueError("Unexpected runtime license path")
        target = output / PurePosixPath(name).name
        raw = read(member)
        target.write_bytes(raw)
        imported.append({"file": target.name, "sha256": hashlib.sha256(raw).hexdigest()})
    profile = {"pythonVersion": version, "pythonBuild": sys.version,
               "libraryUUID": uuid(installed), "installedLibrarySHA256": hashlib.sha256(installed.read_bytes()).hexdigest(),
               "sourceArchiveURL": args.source_url, "sourceArchiveSHA256": args.sha256,
               "matchMethod": "Same Mach-O UUID; install-only runtime is stripped",
               "licenseFiles": imported}
    (output / "manifest.json").write_text(json.dumps(profile, indent=2) + "\n")
    print(json.dumps({"matchedRuntime": version, "runtimeLicenseFiles": len(imported)}))


if __name__ == "__main__":
    main()
