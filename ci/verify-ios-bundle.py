#!/usr/bin/env python3
"""Validate the application and extension metadata shipped by an iOS build."""

from __future__ import annotations

import argparse
import plistlib
import re
from pathlib import Path
from zipfile import BadZipFile, ZipFile


IDENTIFIER_PATTERN = re.compile(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*")
SHORT_VERSION_PATTERN = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+")
BUILD_VERSION_PATTERN = re.compile(r"[0-9]+(?:\.[0-9]+){0,2}")


def _required_string(info: dict, key: str, label: str) -> str:
    value = info.get(key)
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{label} is missing string key {key}")
    return value


def _validate_bundle(info: object, label: str, package_type: str) -> tuple[str, str, str]:
    if not isinstance(info, dict):
        raise ValueError(f"{label} has an invalid Info.plist")
    executable = _required_string(info, "CFBundleExecutable", label)
    if executable in (".", "..") or "/" in executable or "\\" in executable:
        raise ValueError(f"{label} has an invalid CFBundleExecutable")
    identifier = _required_string(info, "CFBundleIdentifier", label)
    if not IDENTIFIER_PATTERN.fullmatch(identifier):
        raise ValueError(f"{label} has an invalid CFBundleIdentifier")
    if info.get("CFBundlePackageType") != package_type:
        raise ValueError(
            f"{label} has package type {info.get('CFBundlePackageType')!r}, "
            f"expected {package_type!r}"
        )
    short_version = _required_string(info, "CFBundleShortVersionString", label)
    if not SHORT_VERSION_PATTERN.fullmatch(short_version):
        raise ValueError(f"{label} has an invalid CFBundleShortVersionString")
    build_version = _required_string(info, "CFBundleVersion", label)
    if not BUILD_VERSION_PATTERN.fullmatch(build_version):
        raise ValueError(f"{label} has an invalid CFBundleVersion")
    return executable, short_version, build_version


def _validate_extension(
    info: object,
    label: str,
    app_version: tuple[str, str],
) -> str:
    executable, short_version, build_version = _validate_bundle(
        info, label, "XPC!"
    )
    if (short_version, build_version) != app_version:
        raise ValueError(
            f"{label} version {short_version} ({build_version}) does not match "
            f"the app version {app_version[0]} ({app_version[1]})"
        )
    return executable


def _load_plist(path: Path) -> object:
    try:
        return plistlib.loads(path.read_bytes())
    except (OSError, plistlib.InvalidFileException, ValueError) as error:
        raise ValueError(f"could not read {path}: {error}") from error


def verify_app(path: Path) -> None:
    if not path.is_dir():
        raise ValueError(f"missing app: {path}")
    app_info = _load_plist(path / "Info.plist")
    app_executable, short_version, build_version = _validate_bundle(
        app_info, str(path), "APPL"
    )
    app_binary = path / app_executable
    if not app_binary.is_file() or app_binary.stat().st_size == 0:
        raise ValueError(f"{path} has no app executable named {app_executable}")

    extensions = sorted((path / "PlugIns").glob("*.appex"))
    if not extensions:
        raise ValueError(f"{path} does not contain any PlugIns/*.appex bundles")
    for extension in extensions:
        info = _load_plist(extension / "Info.plist")
        executable = _validate_extension(
            info, str(extension), (short_version, build_version)
        )
        binary = extension / executable
        if not binary.is_file() or binary.stat().st_size == 0:
            raise ValueError(
                f"{extension} has no executable named {executable}"
            )
    print(f"{path}: app and {len(extensions)} extension bundle(s) verified")


def verify_ipa(path: Path) -> None:
    app_root = "Payload/Runner.app/"
    try:
        with ZipFile(path) as package:
            app_info = plistlib.loads(package.read(app_root + "Info.plist"))
            app_executable, short_version, build_version = _validate_bundle(
                app_info, path.name, "APPL"
            )
            app_binary = package.getinfo(app_root + app_executable)
            if app_binary.file_size == 0:
                raise ValueError(f"{path.name} has an empty app executable")

            extension_infos = sorted(
                name
                for name in package.namelist()
                if re.fullmatch(
                    re.escape(app_root) + r"PlugIns/[^/]+\.appex/Info\.plist", name
                )
            )
            if not extension_infos:
                raise ValueError(
                    f"{path.name} does not contain any PlugIns/*.appex bundles"
                )
            for info_name in extension_infos:
                extension_root = info_name.removesuffix("/Info.plist") + "/"
                info = plistlib.loads(package.read(info_name))
                executable = _validate_extension(
                    info,
                    info_name,
                    (short_version, build_version),
                )
                extension_binary = package.getinfo(extension_root + executable)
                if extension_binary.file_size == 0:
                    raise ValueError(f"{info_name} has an empty extension executable")
    except (BadZipFile, KeyError, plistlib.InvalidFileException, ValueError) as error:
        if isinstance(error, ValueError):
            raise
        raise ValueError(f"invalid IPA {path}: {error}") from error
    print(f"{path}: app and {len(extension_infos)} extension bundle(s) verified")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    target = parser.add_mutually_exclusive_group(required=True)
    target.add_argument("--app", type=Path, help="built Runner.app directory")
    target.add_argument("--ipa", type=Path, help="finished unsigned IPA")
    args = parser.parse_args()
    try:
        if args.app is not None:
            verify_app(args.app)
        else:
            verify_ipa(args.ipa)
    except (OSError, ValueError) as error:
        raise SystemExit(str(error)) from error


if __name__ == "__main__":
    main()
