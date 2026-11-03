#!/usr/bin/env python3
"""Prepare the statically linked Audio Engine before Xcode links Runner."""

from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path
import subprocess
import sys


ARCHIVES = (
    "liblazer-audio.a",
    "liblazer-audio-bridge.a",
    "libavformat.a",
    "libavcodec.a",
    "libavutil.a",
    "libswresample.a",
)
PLATFORMS = {"iphoneos": "device", "iphonesimulator": "simulator"}
SOURCE_SUFFIXES = {".c", ".cc", ".cpp", ".h", ".hpp", ".mm", ".cmake", ".sh", ".map"}


def build_signature(repo: Path, platform: str, environment: dict[str, str]) -> str:
    digest = hashlib.sha256()
    for value in (
        platform,
        environment.get("SDKROOT", ""),
        environment.get("XCODE_VERSION_ACTUAL", ""),
        environment.get("ARCHS", "arm64"),
    ):
        digest.update(value.encode("utf-8") + b"\0")
    sources = [
        path for path in (repo / "native").rglob("*")
        if path.is_file() and (
            path.suffix in SOURCE_SUFFIXES or path.name == "CMakeLists.txt"
        )
    ]
    sources.extend(
        repo / "ci" / name
        for name in ("build-ios-audio.sh", "prepare-ios-audio.py", "verify-ios-audio.py")
    )
    for path in sorted(sources):
        digest.update(path.relative_to(repo).as_posix().encode("utf-8") + b"\0")
        digest.update(path.read_bytes())
    return digest.hexdigest()


def archives_present(directory: Path) -> bool:
    return all(
        (directory / name).is_file() and (directory / name).stat().st_size > 0
        for name in ARCHIVES
    )


def prepare(
    repo: Path,
    sdk: str,
    library_dir: Path | None = None,
    *,
    environment: dict[str, str] | None = None,
    run=None,
) -> None:
    environment = dict(os.environ if environment is None else environment)
    if environment.get("ACTION") == "clean":
        return
    platform = PLATFORMS.get(sdk)
    if platform is None:
        raise ValueError(f"Unsupported iOS SDK: {sdk}")
    default_dir = repo / "build" / "ios-audio" / platform / "stage" / "lib"
    directory = (library_dir or default_dir).resolve()
    run = subprocess.run if run is None else run

    if directory == default_dir.resolve():
        signature = build_signature(repo, platform, environment)
        stamp = directory.parent / "inputs.sha256"
        cached = stamp.read_text(encoding="utf-8").strip() if stamp.is_file() else ""
        if not archives_present(directory) or cached != signature:
            print(f"Building the iOS Audio Engine ({platform})", flush=True)
            run(
                ["bash", str(repo / "ci" / "build-ios-audio.sh"), platform],
                cwd=repo,
                env=environment,
                check=True,
            )
        if not archives_present(directory):
            raise RuntimeError(f"The iOS Audio Engine build left missing archives in {directory}")
    else:
        # CI and custom builds provide their own already-built archives.
        signature = None
        stamp = None
        if not archives_present(directory):
            raise RuntimeError(f"Missing iOS Audio Engine archives in {directory}")

    run(
        [sys.executable, str(repo / "ci" / "verify-ios-audio.py"), "--archive", str(directory)],
        cwd=repo,
        env=environment,
        check=True,
    )
    if stamp is not None:
        stamp.write_text(signature + "\n", encoding="utf-8")
    print(f"iOS Audio Engine ready: {directory}", flush=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", choices=PLATFORMS, required=True)
    parser.add_argument("--library-dir", type=Path)
    args = parser.parse_args()
    try:
        prepare(
            Path(__file__).resolve().parents[1],
            args.platform,
            args.library_dir,
        )
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"error: iOS Audio Engine preparation failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
