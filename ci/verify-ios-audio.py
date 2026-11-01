#!/usr/bin/env python3
"""Verifies that a built iOS app carries the linked native audio engine.

The engine is a static archive inside the Runner binary, so the checks are on
the executable: it must be arm64, it must export the ABI symbols the Dart
loader looks up through `DynamicLibrary.process()`, and it must not have picked
up an FFmpeg shared library from somewhere outside the app.

    python3 ci/verify-ios-audio.py --app build/ios/iphoneos/Runner.app
    python3 ci/verify-ios-audio.py --archive build/ios-audio/device/stage/lib
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

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
    "lazer_audio_set_dsp",
    "lazer_audio_set_device",
    "lazer_audio_snapshot",
    "lazer_audio_stream_info",
    "lazer_audio_last_error",
    "lazer_audio_build_information",
]

# The reader bridge is what makes network sources playable; it is linked with
# the engine, so its absence would silently downgrade streaming.
BRIDGE_SYMBOLS = [
    "lazer_bridge_reader_create",
    "lazer_bridge_reader_notify",
    "lazer_bridge_reader_finish",
    "lazer_bridge_reader_read",
    "lazer_bridge_reader_destroy",
]


def run(*command: str) -> str:
    result = subprocess.run(command, capture_output=True, text=True)
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
    try:
        output = run("dyld_info", "-exports", str(binary))
    except SystemExit:
        return set()
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
    if not symbols:
        symbols = defined_symbols(binary)
        source = "the symbol table (dyld_info unavailable)"
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
    for forbidden in ("libavcodec", "libavformat", "liblazer-audio"):
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
    parser.add_argument("--app", type=Path, help="built Runner.app directory")
    parser.add_argument("--archive", type=Path, help="staged iOS archive directory")
    parser.add_argument("--expect-native", action="store_true", help="fail when the engine is absent")
    args = parser.parse_args()
    if args.app is None and args.archive is None:
        parser.error("pass --app or --archive")
    if args.app is not None:
        name = "Runner"
        binary = args.app / name
        return verify_executable(binary)
    return verify_archive(args.archive)


if __name__ == "__main__":
    raise SystemExit(main())
