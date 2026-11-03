#!/usr/bin/env python3
"""Sign all embedded Mach-O objects with Xcode's chosen identity, child last."""
from __future__ import annotations

import os
from pathlib import Path
import subprocess
import sys

MACHO_MAGICS = {
    b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe",
    b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca",
}


def main() -> None:
    if os.environ.get("CODE_SIGNING_ALLOWED") == "NO":
        print("Nested signing skipped for an explicitly unsigned build.")
        return
    helper = Path(sys.argv[1]).resolve(strict=True)
    entitlements = Path(sys.argv[2]).resolve(strict=True)
    identity = os.environ.get("EXPANDED_CODE_SIGN_IDENTITY")
    if not identity:
        raise SystemExit("Xcode did not provide a signing identity; refusing to silently ad-hoc sign a Store build.")
    executable = helper / "Contents/MacOS/nest-service"
    for path in sorted(helper.rglob("*"), key=lambda value: len(value.parts), reverse=True):
        if not path.is_file() or path.is_symlink() or path == executable:
            continue
        with path.open("rb") as stream:
            is_macho = stream.read(4) in MACHO_MAGICS
        if is_macho:
            subprocess.run(["/usr/bin/codesign", "--force", "--sign", identity, str(path)], check=True)
    for framework in sorted(helper.rglob("*.framework"), key=lambda value: len(value.parts), reverse=True):
        if not framework.is_symlink():
            subprocess.run(["/usr/bin/codesign", "--force", "--sign", identity, str(framework)], check=True)
    subprocess.run([
        "/usr/bin/codesign", "--force", "--options", "runtime", "--sign", identity,
        "--identifier", "dev.htlin.nest-player.cast-service",
        "--entitlements", str(entitlements), str(helper),
    ], check=True)
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(helper)], check=True)


if __name__ == "__main__":
    main()
