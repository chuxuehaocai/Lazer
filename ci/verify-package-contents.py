#!/usr/bin/env python3
"""Check release directories and ZIP/tar archives for excluded FFmpeg materials."""

import argparse
from pathlib import Path, PurePosixPath
import tarfile
from zipfile import BadZipFile, ZipFile


TAR_SUFFIXES = (".tar", ".tar.gz", ".tgz", ".tar.xz", ".tar.bz2", ".tar.zst")
ZIP_SUFFIXES = (".zip", ".apk", ".ipa")


def excluded(name):
    parts = PurePosixPath(name.replace("\\", "/").lower()).parts
    if not parts:
        return False
    filename = parts[-1]
    if "lazer-ffmpeg" in parts:
        return True
    if "ffmpeg" in parts and (
        filename.startswith(("copying", "license"))
        or filename in ("buildinfo.txt", "profile.txt")
    ):
        return True
    return filename.startswith("ffmpeg") and filename.endswith(TAR_SUFFIXES + ZIP_SUFFIXES)


def verify_names(names, label):
    forbidden = sorted({name for name in names if excluded(name)})
    if forbidden:
        raise ValueError(f"{label} contains excluded FFmpeg materials: {', '.join(forbidden)}")


def verify_archive(path):
    name = path.name.lower()
    if name.endswith(ZIP_SUFFIXES):
        with ZipFile(path) as archive:
            verify_names(archive.namelist(), path)
    elif name.endswith(TAR_SUFFIXES):
        with tarfile.open(path) as archive:
            verify_names(archive.getnames(), path)


def verify_package(path):
    if not path.exists():
        raise ValueError(f"missing package: {path}")
    if path.is_dir():
        entries = list(path.rglob("*"))
        verify_names((entry.relative_to(path).as_posix() for entry in entries), path)
        for entry in entries:
            if entry.is_file():
                verify_archive(entry)
    else:
        verify_names((path.name,), path)
        verify_archive(path)
    print(f"{path}: FFmpeg packaging exclusions verified")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("packages", nargs="+", type=Path)
    args = parser.parse_args()
    try:
        for package in args.packages:
            verify_package(package)
    except (OSError, ValueError, BadZipFile, tarfile.TarError) as error:
        raise SystemExit(str(error)) from error


if __name__ == "__main__":
    main()
