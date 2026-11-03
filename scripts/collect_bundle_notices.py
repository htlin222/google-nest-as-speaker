#!/usr/bin/env python3
"""Inventory the frozen artifact, preserve notices, and ship locked source archives.

This is evidence for license review, not an assertion of complete compliance.
PyInstaller archive APIs are pinned to the project's 6.22.0 build dependency.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.metadata as metadata
import json
from pathlib import Path
import re
import shutil
import sys
import sysconfig
import tomllib
import urllib.request

from PyInstaller.archive.readers import CArchiveReader

NOTICE_NAME = re.compile(r"^(?:licen[cs]e|copying|notice)(?:[._-].*)?$", re.IGNORECASE)
EXCLUDED_MODULES = ("mutagen", "PyInstaller", "setuptools", "pkg_resources")


def frozen_modules(executable: Path) -> set[str]:
    archive = CArchiveReader(str(executable))
    modules = set(archive.open_embedded_archive("PYZ.pyz").toc)
    for excluded in EXCLUDED_MODULES:
        if any(name == excluded or name.startswith(excluded + ".") for name in modules):
            raise ValueError(f"Unneeded build/postprocessing package in runtime: {excluded}")
    return modules


def owned_modules(distribution: metadata.Distribution) -> set[str]:
    modules = set()
    for file in distribution.files or []:
        if file.suffix != ".py" or any(part.endswith((".dist-info", ".egg-info")) or part == ".." for part in file.parts):
            continue
        parts = list(file.with_suffix("").parts)
        if parts[-1] == "__init__":
            parts.pop()
        if parts:
            modules.add(".".join(parts))
    return modules


def component(distribution: metadata.Distribution, count: int, role: str) -> tuple[dict, list[str]]:
    meta = distribution.metadata
    texts, names = [], []
    for file in distribution.files or []:
        if not NOTICE_NAME.fullmatch(file.name):
            continue
        path = Path(distribution.locate_file(file))
        if path.is_file():
            names.append(str(file))
            texts.append(f"--- {file} ---\n{path.read_text(encoding='utf-8', errors='replace')}")
    if not texts:
        raise ValueError(f"No license notice found for bundled dependency {meta['Name']}")
    license_name = meta.get("License-Expression") or meta.get("License") or "See included license text"
    return {
        "name": meta["Name"], "version": distribution.version,
        "licenseMetadata": license_name, "role": role,
        "frozenPythonModules": count, "noticeFiles": names,
        "projectURLs": meta.get_all("Project-URL", []),
    }, texts


def source_archive(package: dict, output: Path) -> dict:
    source = package["sdist"]
    expected = source["hash"].removeprefix("sha256:")
    name = f"{package['name']}-{package['version']}.tar.gz"
    path = output / name
    if path.exists() and hashlib.sha256(path.read_bytes()).hexdigest() == expected:
        data = path.read_bytes()
    else:
        # Download data only. Never execute or extract package build scripts.
        with urllib.request.urlopen(source["url"], timeout=30) as response:
            data = response.read(source["size"] + 1)
        if len(data) != source["size"] or hashlib.sha256(data).hexdigest() != expected:
            raise ValueError(f"Locked source hash/size mismatch: {name}")
        path.write_bytes(data)
    return {"file": name, "url": source["url"], "sha256": expected, "bytes": len(data)}


def collect(helper: Path, repo: Path) -> dict:
    application = helper.suffix == ".app"
    executable = helper / "Contents/MacOS/nest-service" if application else helper / "nest-service"
    output = helper / "Contents/Resources" if application else helper
    modules = frozen_modules(executable)
    components, notices = [], ["Nest Player — third-party notices\n\nGenerated from the frozen helper's module inventory.\n"]
    for distribution in sorted(metadata.distributions(), key=lambda item: item.metadata["Name"].lower()):
        included = owned_modules(distribution) & modules
        if not included:
            continue
        info, texts = component(distribution, len(included), "runtime Python dependency")
        components.append(info)
        notices.append(f"\n===== {info['name']} {info['version']} =====\n" + "\n".join(texts))
    bootloader, texts = component(metadata.distribution("pyinstaller"), 0, "PyInstaller bootloader; build package excluded")
    components.append(bootloader)
    notices.append(f"\n===== PyInstaller bootloader {bootloader['version']} =====\n" + "\n".join(texts))
    python_license = Path(sysconfig.get_path("stdlib")) / "LICENSE.txt"
    notices.append("\n===== CPython =====\n" + python_license.read_text())
    runtime = {"verified": False}
    runtime_profile = repo / "AppStore/RuntimeLicenses/manifest.json"
    if runtime_profile.exists():
        profile = json.loads(runtime_profile.read_text())
        library = Path(sys.base_prefix) / f"lib/libpython{sys.version_info.major}.{sys.version_info.minor}.dylib"
        if library.exists() and hashlib.sha256(library.read_bytes()).hexdigest() == profile["installedLibrarySHA256"]:
            destination = output / "RuntimeNotices"
            destination.mkdir(exist_ok=True)
            shutil.copy2(runtime_profile, destination / "manifest.json")
            for entry in profile["licenseFiles"]:
                source = runtime_profile.parent / entry["file"]
                if hashlib.sha256(source.read_bytes()).hexdigest() != entry["sha256"]:
                    raise ValueError("Runtime license text hash differs from reviewed profile")
                shutil.copy2(source, destination / entry["file"])
                notices.append(f"\n===== Runtime: {entry['file']} =====\n" + source.read_text())
            runtime = {"verified": True, "libraryUUID": profile["libraryUUID"],
                       "licenseFiles": len(profile["licenseFiles"]), "sourceArchiveSHA256": profile["sourceArchiveSHA256"]}
    source_output = output / "ThirdPartySources"
    source_output.mkdir(exist_ok=True)
    lock = tomllib.loads((repo / "uv.lock").read_text())
    packages = {package["name"]: package for package in lock["package"]}
    for info in components:
        if info["name"].lower() in {"zeroconf", "certifi"}:
            package = packages[info["name"].lower()]
            if "sdist" in package:
                info["correspondingSource"] = source_archive(package, source_output)
            else:
                # Permit rebuilding a modified local library. Publishing that
                # build requires supplying the modified corresponding source.
                info["localModifiedSourceNeedsPackaging"] = True
    report = {
        "format": "NestPlayerFrozenDependencyInventory-v1",
        "pythonVersion": sys.version.split()[0], "pythonBuild": sys.version,
        "frozenPythonModuleCount": len(modules), "excludedRuntimePackages": list(EXCLUDED_MODULES),
        "runtimeLicenseProfile": runtime,
        "components": components,
        "reviewRemaining": [
            "Supported CPython/OpenSSL security patch level",
            "LGPL/MPL obligations, rebuild/relink instructions, and final distribution terms",
            "Final website-media scope and provider authorization",
        ],
    }
    if not runtime["verified"]:
        report["reviewRemaining"].insert(0, "Runtime native dependency licenses need a matching upstream profile")
    if any(info.get("localModifiedSourceNeedsPackaging") for info in components):
        report["reviewRemaining"].append("Package modified local LGPL/MPL library source before redistribution")
    (output / "DependencyInventory.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    (output / "ThirdPartyNotices.txt").write_text("\n".join(notices), encoding="utf-8")
    (source_output / "README.txt").write_text(
        "Unmodified upstream source archives, pinned and SHA-256 checked against uv.lock.\n"
        "DependencyInventory.json records their exact source URL and hash.\n"
        "Nest Player source and helper build scripts:\n"
        "https://github.com/htlin222/google-nest-as-speaker\n"
        "Build/relink and license review notes: docs/app-store/dependencies.md\n"
    )
    return report


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("helper", type=Path)
    args = parser.parse_args()
    report = collect(args.helper.resolve(strict=True), Path(__file__).resolve().parents[1])
    print(json.dumps({"bundledComponents": len(report["components"]), "frozenModules": report["frozenPythonModuleCount"]}))


if __name__ == "__main__":
    main()
