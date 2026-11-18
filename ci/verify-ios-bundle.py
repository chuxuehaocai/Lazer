#!/usr/bin/env python3
"""Validate the application and extension metadata shipped by an iOS build."""

from __future__ import annotations

import argparse
import plistlib
import re
from pathlib import Path, PurePosixPath
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
    _required_string(info, "CFBundleName", label)
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
    app_identifier: str,
) -> str:
    executable, short_version, build_version = _validate_bundle(
        info, label, "XPC!"
    )
    if (short_version, build_version) != app_version:
        raise ValueError(
            f"{label} version {short_version} ({build_version}) does not match "
            f"the app version {app_version[0]} ({app_version[1]})"
        )
    if not info["CFBundleIdentifier"].startswith(app_identifier + "."):
        raise ValueError(f"{label} identifier must start with {app_identifier}.")
    return executable


WIDGET_EXTENSION_POINT = "com.apple.widgetkit-extension"
APP_GROUP_KEY = "com.apple.security.application-groups"


def _entitlements(path: Path, label: str) -> dict:
    """Reads a signing entitlement file, or an empty dict when it is absent.

    An absent ``CODE_SIGN_ENTITLEMENTS`` silently changes what the bundle can do,
    so the caller is expected to pass a path it already required to exist.
    """
    try:
        value = plistlib.loads(path.read_bytes())
    except (OSError, plistlib.InvalidFileException, ValueError) as error:
        raise ValueError(f"could not read {label}: {error}") from error
    if not isinstance(value, dict):
        raise ValueError(f"{label} is not a dictionary")
    return value


XCCONFIG_SETTING = "LAZER_APP_GROUP_IDENTIFIER"
APP_GROUP_XCCONFIG = Path("ios/Flutter/LazerAppGroup.xcconfig")


def _xcconfig_setting(path: Path, name: str) -> str | None:
    """The last assignment of ``name`` in an xcconfig, which is the one that wins."""
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        # A missing settings file means the setting is simply not defined; the
        # caller reports that as the actionable problem.
        return None
    value = None
    for raw in text.splitlines():
        line = raw.split("//", 1)[0].strip()
        if not line or line.startswith("#"):
            continue
        key, _, assigned = line.partition("=")
        if key.strip() == name:
            value = assigned.strip()
    return value


def _group_entry(entitlements: dict) -> str:
    """The single application-group entry, which may still hold an xcconfig variable."""
    groups = entitlements.get(APP_GROUP_KEY)
    if not isinstance(groups, list) or not groups:
        return ""
    if len(groups) != 1:
        raise ValueError(
            f"{APP_GROUP_KEY} must name exactly one group, found {groups!r}"
        )
    entry = groups[0]
    if not isinstance(entry, str) or not entry:
        raise ValueError(f"{APP_GROUP_KEY} has an invalid entry: {entry!r}")
    return entry


def verify_shared_container_contract(repo: Path) -> str:
    """The widget can only read what the app writes into one shared App Group.

    Both targets must declare the *same* group. When they differ - or when either
    side loses the entitlement, which is what a re-signed sideload produces - the
    extension's ``containerURL`` returns nil, every snapshot the app writes lands
    somewhere the widget cannot see, and the home-screen card stays empty with no
    error anywhere. That is exactly the "widget shows nothing" failure, so it is
    checked here rather than discovered on a device.
    """
    runner = _entitlements(
        repo / "ios" / "Runner" / "Runner.entitlements",
        "Runner.entitlements",
    )
    widget = _entitlements(
        repo / "ios" / "Widget" / "Widget.entitlements",
        "Widget.entitlements",
    )
    runner_entry = _group_entry(runner)
    widget_entry = _group_entry(widget)
    if not runner_entry:
        raise ValueError(
            "Runner.entitlements declares no application groups, so the widget "
            "extension cannot read the app's playback snapshot"
        )
    if not widget_entry:
        raise ValueError(
            "Widget.entitlements declares no application groups, so the "
            "extension cannot read the app's playback snapshot"
        )
    # Both sides must name the same thing, whether that is one literal or one
    # variable: Xcode substitutes the same build setting into both files, so a
    # shared variable is as safe as a shared literal and a split is not.
    if runner_entry != widget_entry:
        raise ValueError(
            "the app and the widget extension name different application "
            f"groups: {runner_entry!r} vs {widget_entry!r}; they cannot share a "
            "container, so the widget stays empty"
        )

    if "$(" in runner_entry:
        configured = _xcconfig_setting(repo / APP_GROUP_XCCONFIG, XCCONFIG_SETTING)
        if configured is None:
            raise ValueError(
                f"{APP_GROUP_XCCONFIG} does not define {XCCONFIG_SETTING}"
            )
        if runner_entry != f"$({XCCONFIG_SETTING})":
            raise ValueError(
                f"the entitlements name {runner_entry!r}, which is not a build "
                f"setting this project defines; only $({XCCONFIG_SETTING}) is"
            )
        resolved = configured
    else:
        resolved = runner_entry

    if not resolved.startswith("group."):
        raise ValueError(
            f"invalid application group: {resolved!r}; it must start with 'group.'"
        )
    if " " in resolved or resolved.endswith("group."):
        raise ValueError(f"invalid application group: {resolved!r}")
    return resolved


def verify_widget_extension_point(info: object, label: str) -> None:
    """Every extension must be a WidgetKit extension for this app to be useful."""
    if not isinstance(info, dict):
        raise ValueError(f"{label} has an invalid Info.plist")
    extension = info.get("NSExtension")
    if not isinstance(extension, dict):
        raise ValueError(f"{label} declares no NSExtension")
    point = extension.get("NSExtensionPointIdentifier")
    if point != WIDGET_EXTENSION_POINT:
        raise ValueError(
            f"{label} declares extension point {point!r}, "
            f"expected {WIDGET_EXTENSION_POINT!r}"
        )


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
            info, str(extension), (short_version, build_version),
            app_info["CFBundleIdentifier"],
        )
        verify_widget_extension_point(info, str(extension))
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
            # ZipInfo normalizes backslashes and truncates NULs on Windows;
            # validate the original central-directory spellings first.
            names = [item.orig_filename for item in package.infolist()]
            if len(names) != len(set(names)):
                raise ValueError(f"{path.name} contains duplicate ZIP entries")
            if any(not name.startswith("Payload/") for name in names):
                raise ValueError(f"{path.name} contains files outside Payload/")
            if any("\\" in name or re.search(r"[\x00-\x1f]", name)
                   or PurePosixPath(name).is_absolute()
                   or ".." in PurePosixPath(name).parts
                   or PurePosixPath(name).as_posix() != name.rstrip("/")
                   for name in names):
                raise ValueError(f"{path.name} contains unsafe ZIP paths")
            app_info = plistlib.loads(package.read(app_root + "Info.plist"))
            app_executable, short_version, build_version = _validate_bundle(
                app_info, path.name, "APPL"
            )
            app_binary = package.getinfo(app_root + app_executable)
            if app_binary.file_size == 0:
                raise ValueError(f"{path.name} has an empty app executable")

            # Discover extension roots from every entry, including an appex
            # whose Info.plist was lost during packaging.
            extension_roots = sorted({
                match.group(1) for name in names
                if (match := re.match(
                    re.escape(app_root) + r"(PlugIns/[^/]+\.appex)(?:/|$)", name
                ))
            })
            extension_infos = [app_root + root + "/Info.plist" for root in extension_roots]
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
                    app_info["CFBundleIdentifier"],
                )
                verify_widget_extension_point(info, info_name)
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
        group = verify_shared_container_contract(Path(__file__).resolve().parents[1])
        print(f"shared application group: {group}")
        if args.app is not None:
            verify_app(args.app)
        else:
            verify_ipa(args.ipa)
    except (OSError, ValueError) as error:
        raise SystemExit(str(error)) from error


if __name__ == "__main__":
    main()
