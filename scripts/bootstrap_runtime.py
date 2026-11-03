#!/usr/bin/env python3
"""Fetch a digest-pinned build interpreter into this workspace; no global install.

Uses only Python 3.9+ standard library so the macOS system interpreter can
bootstrap the qualified runtime. Nothing is downloaded when the app runs.
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import platform
import subprocess
import sys
import tempfile
import urllib.request


def main() -> None:
    repo = Path(__file__).resolve().parents[1]
    lock = json.loads((repo / "AppStore/Runtime.lock.json").read_text())
    if platform.system() != lock["platform"] or platform.machine() != lock["architecture"]:
        raise SystemExit("The qualified packaging runtime currently targets Apple silicon macOS.")
    build = repo / ".build"
    build.mkdir(exist_ok=True)
    artifact = lock["installArchive"]
    root = build / "runtimes" / artifact["sha256"][:16]
    executable = root / "python/bin" / ("python" + ".".join(lock["pythonVersion"].split(".")[:2]))
    if not executable.exists():
        downloads = build / "runtime-downloads"
        downloads.mkdir(exist_ok=True)
        archive = downloads / artifact["filename"]
        if not archive.exists() or hashlib.sha256(archive.read_bytes()).hexdigest() != artifact["sha256"]:
            print("Fetching the pinned Nest Player build runtime…", file=sys.stderr)
            with urllib.request.urlopen(artifact["url"], timeout=60) as response:
                raw = response.read(artifact["bytes"] + 1)
            if len(raw) != artifact["bytes"] or hashlib.sha256(raw).hexdigest() != artifact["sha256"]:
                raise SystemExit("Runtime archive does not match the pinned size and SHA-256.")
            archive.write_bytes(raw)
        staging = Path(tempfile.mkdtemp(prefix="runtime-stage-", dir=build))
        subprocess.run(["/usr/bin/tar", "-xzf", str(archive), "-C", str(staging), "--no-same-owner"], check=True)
        root.parent.mkdir(exist_ok=True)
        staging.rename(root)
    probe = "import sys,ssl,pyexpat,json; print(json.dumps([sys.version.split()[0],ssl.OPENSSL_VERSION,pyexpat.EXPAT_VERSION]))"
    actual = json.loads(subprocess.check_output([str(executable), "-c", probe], text=True))
    if actual != [lock["pythonVersion"], lock["opensslVersion"], lock["expatVersion"]]:
        raise SystemExit("Cached runtime differs from the qualified Python/OpenSSL/Expat baseline.")
    print(executable)


if __name__ == "__main__":
    main()
