#!/usr/bin/env python3
"""Check signed packaging evidence; does not assert App Store or legal readiness."""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess

from collect_bundle_notices import frozen_modules

MACHO_MAGICS = {bytes.fromhex(value) for value in (
    "feedface", "cefaedfe", "feedfacf", "cffaedfe", "cafebabe", "bebafeca", "cafebabf", "bfbafeca",
)}
APP_REASONS = {
    "NSPrivacyAccessedAPICategoryUserDefaults": {"CA92.1"},
    "NSPrivacyAccessedAPICategoryFileTimestamp": {"C617.1", "3B52.1"},
}
HELPER_REASONS = {
    "NSPrivacyAccessedAPICategoryFileTimestamp": {"C617.1"},
    "NSPrivacyAccessedAPICategorySystemBootTime": {"35F9.1"},
}


def command(*args: str) -> str:
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout


def entitlements(path: Path) -> dict:
    return plistlib.loads(command("/usr/bin/codesign", "-d", "--entitlements", ":-", str(path)).encode())


def team(path: Path) -> str:
    result = subprocess.run(["/usr/bin/codesign", "-dv", str(path)], check=True, capture_output=True, text=True)
    match = re.search(r"^TeamIdentifier=(.+)$", result.stderr, re.MULTILINE)
    if not match or match[1] == "not set":
        raise ValueError("The engineering Store bundle must use a real signing identity")
    return match[1]


def verify_reasons(path: Path, expected: dict[str, set[str]]) -> None:
    data = plistlib.loads(path.read_bytes())
    declared = {}
    for item in data["NSPrivacyAccessedAPITypes"]:
        category = item["NSPrivacyAccessedAPIType"]
        if category in declared:
            raise ValueError(f"Duplicate privacy API category: {path.name}")
        declared[category] = set(item["NSPrivacyAccessedAPITypeReasons"])
    if declared != expected:
        raise ValueError(f"Privacy API reasons differ from reviewed engineering use: {path.name}")


def system_path(path: str) -> bool:
    return path.startswith(("/System/Library/Frameworks/", "/usr/lib/"))


def audit_load_commands(path: Path) -> list[str]:
    failures = []
    for line in command("/usr/bin/otool", "-L", str(path)).splitlines()[1:]:
        if not line.startswith("\t"):
            continue
        dependency = line.strip().split(" (compatibility version", 1)[0]
        if not system_path(dependency) and not dependency.startswith(("@rpath/", "@loader_path/", "@executable_path/")):
            failures.append(dependency)
    # Relative load commands can still escape via a hardcoded build-machine rpath.
    commands = command("/usr/bin/otool", "-l", str(path))
    for rpath in re.findall(r"cmd LC_RPATH\n\s*cmdsize \d+\n\s*path (.*?) \(offset", commands):
        if not system_path(rpath + "/") and not rpath.startswith(("@loader_path", "@executable_path")):
            failures.append(rpath)
    return failures


def verify(app: Path) -> dict:
    app = app.resolve(strict=True)
    helper = app / "Contents/Helpers/NestCastService.app"
    resources = helper / "Contents/Resources"
    command("/usr/bin/codesign", "--verify", "--deep", "--strict", str(app))
    parent = entitlements(app)
    for key in ("app-sandbox", "network.client", "network.server", "files.user-selected.read-only", "files.bookmarks.app-scope"):
        if parent.get("com.apple.security." + key) is not True:
            raise ValueError(f"Missing application sandbox entitlement: {key}")
    if entitlements(helper) != {"com.apple.security.app-sandbox": True, "com.apple.security.inherit": True}:
        raise ValueError("Helper must have exactly sandbox and inheritance entitlements")
    if team(app) != team(helper):
        raise ValueError("Application/helper signing teams differ")
    verify_reasons(app / "Contents/Resources/PrivacyInfo.xcprivacy", APP_REASONS)
    verify_reasons(resources / "PrivacyInfo.xcprivacy", HELPER_REASONS)
    count = len(frozen_modules(helper / "Contents/MacOS/nest-service"))
    native = []
    for path in app.rglob("*"):
        if path.is_symlink():
            if not path.resolve(strict=True).is_relative_to(app):
                raise ValueError(f"Bundle symlink escapes application: {path.relative_to(app)}")
        elif path.is_file():
            with path.open("rb") as stream:
                if stream.read(4) in MACHO_MAGICS:
                    native.append(path)
    with ThreadPoolExecutor(max_workers=8) as workers:
        for path, failures in zip(native, workers.map(audit_load_commands, native), strict=True):
            if failures:
                raise ValueError(f"External/private library dependency in {path.relative_to(app)}: {failures}")
    inventory = json.loads((resources / "DependencyInventory.json").read_text())
    baseline = json.loads((Path(__file__).resolve().parents[1] / "AppStore/Runtime.lock.json").read_text())
    if not inventory.get("runtimeBaselineMatches") or any(inventory[key] != baseline[key] for key in ("pythonVersion", "opensslVersion", "expatVersion")):
        raise ValueError("Packaged runtime differs from the reviewed security baseline")
    if inventory["frozenPythonModuleCount"] != count:
        raise ValueError("Dependency inventory does not match the frozen artifact")
    if not (resources / "ThirdPartyNotices.txt").stat().st_size:
        raise ValueError("Empty third-party notices")
    if not inventory.get("runtimeLicenseProfile", {}).get("verified"):
        raise ValueError("Build interpreter lacks a matching reviewed native-runtime license profile")
    runtime = json.loads((resources / "RuntimeNotices/manifest.json").read_text())
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if tuple(map(int, runtime["minimumMacOS"].split("."))) > tuple(map(int, info["LSMinimumSystemVersion"].split("."))):
        raise ValueError("Embedded runtime requires a newer macOS than the application's minimum")
    library = helper / "Contents/Frameworks" / f"libpython{'.'.join(runtime['pythonVersion'].split('.')[:2])}.dylib"
    actual_uuid = command("/usr/bin/dwarfdump", "--uuid", str(library)).split()[1]
    if actual_uuid != runtime["libraryUUID"]:
        raise ValueError("Frozen native runtime differs from the reviewed upstream build")
    for notice in runtime["licenseFiles"]:
        raw = (resources / "RuntimeNotices" / notice["file"]).read_bytes()
        if hashlib.sha256(raw).hexdigest() != notice["sha256"]:
            raise ValueError("Packaged native-runtime license text hash differs")
    sources = 0
    for component in inventory["components"]:
        if source := component.get("correspondingSource"):
            data = (resources / "ThirdPartySources" / source["file"]).read_bytes()
            if hashlib.sha256(data).hexdigest() != source["sha256"]:
                raise ValueError(f"Corresponding-source hash differs: {component['name']}")
            sources += 1
    return {"engineeringBundleChecks": "passed", "signedMachOFiles": len(native),
            "pythonVersion": inventory["pythonVersion"], "opensslVersion": inventory["opensslVersion"], "expatVersion": inventory["expatVersion"],
            "frozenPythonModules": count, "dependencyComponents": len(inventory["components"]),
            "verifiedSourceArchives": sources, "reviewRemaining": inventory["reviewRemaining"]}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("app", type=Path)
    args = parser.parse_args()
    print(json.dumps(verify(args.app), ensure_ascii=False))


if __name__ == "__main__":
    main()
