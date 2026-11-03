#!/usr/bin/env python3
"""Generate icon catalog and helper resources before Xcode project generation."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sysconfig
import sys
import tempfile


def helper_fingerprint(root: Path) -> str:
    digest = hashlib.sha256(sys.version.encode())
    inputs = [root / name for name in (
        "uv.lock", "pyproject.toml", "scripts/build_helper.sh",
        "scripts/collect_bundle_notices.py", "AppStore/HelperPrivacyInfo.xcprivacy",
    )]
    inputs += sorted((root / ".agents/skills/google-nest-speaker/scripts").glob("*.py"))
    inputs += sorted((root / "AppStore/RuntimeLicenses").glob("*"))
    for path in inputs:
        digest.update(str(path.relative_to(root)).encode())
        digest.update(path.read_bytes())
    return digest.hexdigest()


def main() -> None:
    root = Path(__file__).resolve().parents[1]
    resources = root / ".build/StoreResources"
    resources.mkdir(parents=True, exist_ok=True)
    iconset = resources / "Assets.xcassets/AppIcon.appiconset"
    iconset.mkdir(parents=True, exist_ok=True)
    images = []
    for size in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            filename = f"icon-{size}@{scale}x.png"
            pixels = str(size * scale)
            subprocess.run([
                "/usr/bin/sips", "-z", pixels, pixels, str(root / "assets/nest-player.png"),
                "--out", str(iconset / filename),
            ], check=True, stdout=subprocess.DEVNULL)
            images.append({"idiom": "mac", "size": f"{size}x{size}", "scale": f"{scale}x", "filename": filename})
    (iconset / "Contents.json").write_text(json.dumps({"images": images, "info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
    (iconset.parent / "Contents.json").write_text('{"info":{"author":"xcode","version":1}}\n')
    shutil.copy2(Path(sysconfig.get_path("stdlib")) / "LICENSE.txt", resources / "PYTHON-LICENSE.txt")
    helper = resources / "NestCastService.app"
    stamp = resources / "helper-fingerprint.txt"
    fingerprint = helper_fingerprint(root)
    if not helper.exists() or not stamp.exists() or stamp.read_text().strip() != fingerprint:
        # Build separately so a failed freeze never destroys the last good helper.
        staging = Path(tempfile.mkdtemp(prefix="store-helper-", dir=root / ".build"))
        subprocess.run(["/bin/bash", str(root / "scripts/build_helper.sh"), str(staging / "NestCastService.app"), "app"], check=True)
        if helper.exists():
            helper.rename(staging / "previous-service")
        (staging / "NestCastService.app").rename(helper)
        stamp.write_text(fingerprint + "\n")
    print(resources)


if __name__ == "__main__":
    main()
