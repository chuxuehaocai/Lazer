#!/usr/bin/env python3
"""Verifies that a built iOS app carries the linked native audio engine.

The engine is a static archive inside the Runner binary, so the checks are on
the executable: it must be arm64, it must export the ABI symbols the Dart
loader looks up through `DynamicLibrary.process()`, and it must not have picked
up an FFmpeg shared library from somewhere outside the app.

    python3 ci/verify-ios-audio.py --app build/ios/iphoneos/Runner.app
    python3 ci/verify-ios-audio.py --ipa dist/Lazer-iOS-aarch64.ipa
    python3 ci/verify-ios-audio.py --archive build/ios-audio/device/stage/lib
"""

from __future__ import annotations

import argparse
import plistlib
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from zipfile import BadZipFile, ZipFile

# Kept in step with lib/audio/native/lazer_audio_library.dart.
ABI_SYMBOLS = [
    "lazer_audio_abi_version",
    "lazer_audio_create",
    "lazer_audio_destroy",
    "lazer_audio_open_file_utf8",
    "lazer_audio_open_reader",
    "lazer_audio_queue_reader",
    "lazer_audio_clear_queued_reader",
    "lazer_audio_play",
    "lazer_audio_pause",
    "lazer_audio_stop",
    "lazer_audio_seek",
    "lazer_audio_set_volume",
    "lazer_audio_set_automix",
    "lazer_audio_set_dsp",
    "lazer_audio_set_device",
    "lazer_audio_snapshot",
    "lazer_audio_stream_info",
    "lazer_audio_last_error",
    "lazer_audio_build_information",
]

# The reader bridge is what makes network sources playable; it is linked with
# the engine, so its absence would silently downgrade streaming. The length entry
# is what lets a demuxer turn a seek into a byte offset at all, so it is required
# for the same reason: Dart looks it up and treats a missing symbol as "this
# bridge cannot report the source length".
BRIDGE_SYMBOLS = [
    "lazer_bridge_reader_create",
    "lazer_bridge_reader_notify",
    "lazer_bridge_reader_finish",
    "lazer_bridge_reader_bytes_available",
    "lazer_bridge_reader_read",
    "lazer_bridge_reader_seek",
    "lazer_bridge_reader_length",
    "lazer_bridge_reader_close",
    "lazer_bridge_reader_cancel",
    "lazer_bridge_reader_destroy",
    "lazer_bridge_reader_set_length",
]


def run(*command: str) -> str:
    try:
        result = subprocess.run(command, capture_output=True, text=True)
    except OSError as error:
        raise SystemExit(f"Could not run {command[0]}: {error}") from error
    if result.returncode != 0:
        raise SystemExit(f"{' '.join(command)} failed:\n{result.stderr.strip()}")
    return result.stdout


def defined_symbols(path: Path) -> set[str]:
    output = run("nm", "-g", "--defined-only", str(path))
    symbols = set()
    for line in output.splitlines():
        parts = line.split()
        if not parts:
            continue
        # Mach-O symbols carry a leading underscore.
        symbols.add(parts[-1].lstrip("_"))
    return symbols


def exported_symbols(binary: Path) -> set[str]:
    """The dynamic export trie, which is what dlsym(RTLD_DEFAULT) reads.

    A release build strips the ordinary symbol table, so `nm` alone cannot prove
    that `DynamicLibrary.process()` would find the engine. `dyld_info -exports`
    reads the trie the dynamic loader actually uses.
    """
    output = run("dyld_info", "-exports", str(binary))
    symbols = set()
    for line in output.splitlines():
        parts = line.split()
        if not parts:
            continue
        token = parts[-1]
        if token.startswith("_"):
            symbols.add(token.lstrip("_"))
    return symbols


def verify_executable(binary: Path) -> int:
    if not binary.is_file():
        raise SystemExit(f"missing executable: {binary}")
    arch = run("lipo", "-info", str(binary))
    if "arm64" not in arch:
        raise SystemExit(f"{binary.name} is not an arm64 executable: {arch.strip()}")

    symbols = exported_symbols(binary)
    source = "the dynamic export trie"
    missing = [name for name in ABI_SYMBOLS if name not in symbols]
    missing_bridge = [name for name in BRIDGE_SYMBOLS if name not in symbols]
    if missing or missing_bridge:
        if missing:
            print(
                f"missing engine symbols in {binary.name} ({source}): {', '.join(missing)}",
                file=sys.stderr,
            )
        if missing_bridge:
            print(
                f"missing bridge symbols in {binary.name} ({source}): "
                f"{', '.join(missing_bridge)}",
                file=sys.stderr,
            )
        return 1

    linked = run("otool", "-L", str(binary))
    for line in linked.splitlines()[1:]:
        name = line.strip().split(" ")[0]
        if name.startswith("/usr/lib/") or name.startswith("/System/"):
            continue
        if "@rpath/" in name or "@executable_path/" in name:
            continue
        raise SystemExit(f"{binary.name} links an unexpected image: {name}")
    for forbidden in (
        "libavcodec", "libavformat", "libavutil", "libswresample", "liblazer-audio",
    ):
        if forbidden in linked:
            raise SystemExit(
                f"{binary.name} still links {forbidden} as a shared library; "
                "the engine must be linked statically on iOS"
            )
    print(
        f"{binary.name}: arm64, {len(ABI_SYMBOLS)} engine + {len(BRIDGE_SYMBOLS)} bridge "
        "symbols exported, no stray dylibs"
    )
    return 0


def bundle_executable(info, label: str) -> str:
    if not isinstance(info, dict):
        raise SystemExit(f"{label} has an invalid Info.plist")
    identifier = info.get("CFBundleIdentifier")
    if not isinstance(identifier, str) or not re.fullmatch(
        r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*", identifier
    ):
        raise SystemExit(f"{label} has an invalid CFBundleIdentifier")
    if info.get("CFBundlePackageType") != "APPL":
        raise SystemExit(f"{label} has an invalid CFBundlePackageType")
    for key, pattern in (
        ("CFBundleShortVersionString", r"[0-9]+\.[0-9]+\.[0-9]+"),
        ("CFBundleVersion", r"[0-9]+(?:\.[0-9]+){0,2}"),
    ):
        value = info.get(key)
        if not isinstance(value, str) or not re.fullmatch(pattern, value):
            raise SystemExit(f"{label} has an invalid {key}: {value!r}")
    executable = info.get("CFBundleExecutable")
    if (
        not isinstance(executable, str) or not executable
        or executable in (".", "..") or "/" in executable or "\\" in executable
    ):
        raise SystemExit(f"{label} has an invalid CFBundleExecutable")
    return executable


def verify_app(path: Path) -> int:
    if (path / "Resources").exists():
        raise SystemExit(f"{path} has a reserved top-level Resources directory")
    try:
        info = plistlib.loads((path / "Info.plist").read_bytes())
    except (OSError, plistlib.InvalidFileException, ValueError) as error:
        raise SystemExit(f"Invalid app {path}: {error}") from error
    return verify_executable(path / bundle_executable(info, str(path)))


def verify_ipa(path: Path) -> int:
    """Inspect the executable from the finished package, after all copying/ZIP steps."""
    if not path.is_file():
        raise SystemExit(f"missing IPA: {path}")
    try:
        with ZipFile(path) as package:
            bundle = "Payload/Runner.app/"
            if any(
                name == bundle + "Resources" or name.startswith(bundle + "Resources/")
                for name in package.namelist()
            ):
                raise SystemExit(f"{path.name} has a reserved top-level Resources directory")
            info = plistlib.loads(package.read(bundle + "Info.plist"))
            executable = bundle_executable(info, path.name)
            contents = package.read(bundle + executable)
            if not contents:
                raise SystemExit(f"{path.name} has an empty app executable")
    except (BadZipFile, KeyError, plistlib.InvalidFileException, ValueError) as error:
        raise SystemExit(f"Invalid IPA {path}: {error}") from error
    # Extract only the named binary. No ZIP paths are ever used as local paths.
    with tempfile.TemporaryDirectory(prefix="lazer-ipa-audio-") as directory:
        binary = Path(directory) / executable
        binary.write_bytes(contents)
        result = verify_executable(binary)
    if result == 0:
        print(f"{path.name}: packaged native engine and reader bridge verified")
    return result


def verify_archive(directory: Path) -> int:
    if not directory.is_dir():
        raise SystemExit(f"missing directory: {directory}")
    required = [
        "liblazer-audio.a",
        "liblazer-audio-bridge.a",
        "libavformat.a",
        "libavcodec.a",
        "libavutil.a",
        "libswresample.a",
    ]
    for name in required:
        archive = directory / name
        if not archive.is_file():
            raise SystemExit(f"missing archive: {archive}")
        if "arm64" not in run("lipo", "-info", str(archive)):
            raise SystemExit(f"{name} is not an arm64 archive")
    symbols = defined_symbols(directory / "liblazer-audio.a")
    missing = [name for name in ABI_SYMBOLS if name not in symbols]
    if missing:
        print(f"missing symbols in liblazer-audio.a: {', '.join(missing)}", file=sys.stderr)
        return 1
    bridge = defined_symbols(directory / "liblazer-audio-bridge.a")
    missing_bridge = [name for name in BRIDGE_SYMBOLS if name not in bridge]
    if missing_bridge:
        print(
            f"missing symbols in liblazer-audio-bridge.a: {', '.join(missing_bridge)}",
            file=sys.stderr,
        )
        return 1
    print(
        f"{directory}: {len(required)} arm64 archives, engine ABI and bridge exports complete"
    )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    target = parser.add_mutually_exclusive_group(required=True)
    target.add_argument("--app", type=Path, help="built Runner.app directory")
    target.add_argument("--ipa", type=Path, help="finished unsigned device IPA")
    target.add_argument("--archive", type=Path, help="staged iOS archive directory")
    parser.add_argument("--expect-native", action="store_true", help="fail when the engine is absent")
    args = parser.parse_args()
    if args.ipa is not None:
        return verify_ipa(args.ipa)
    if args.app is not None:
        return verify_app(args.app)
    return verify_archive(args.archive)


if __name__ == "__main__":
    raise SystemExit(main())
