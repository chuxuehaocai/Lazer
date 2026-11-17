#!/usr/bin/env python3
"""Ship the static-LGPL relinking materials beside the runnable APK."""

import argparse
import hashlib
import json
import tarfile
from pathlib import Path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--build", type=Path, required=True)
    parser.add_argument("--ffmpeg", type=Path, required=True)
    parser.add_argument("--abi", choices=("arm64-v8a", "armeabi-v7a", "x86_64"), required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parent.parent
    objects = sorted((args.build / "lazer-audio/CMakeFiles/lazer-audio.dir").rglob("*.o"))
    if not objects:
        raise SystemExit("Missing relinkable engine objects")
    materials = [(path, f"objects/{path.name}") for path in objects]
    if len({name for _, name in materials}) != len(materials):
        raise SystemExit("Object file names must be unique in the relink package")
    for component in ("avformat", "avcodec", "swresample", "avutil"):
        materials.append((args.ffmpeg / f"lib/lib{component}.a", f"ffmpeg/lib/lib{component}.a"))
    usb = json.loads((args.build / "lazer-audio/android-usb-relink.json").read_text(encoding="utf-8"))
    usb_source = Path(usb["source"])
    materials.append((Path(usb["archive"]), "libusb/lib/libusb-1.0.a"))
    materials.append((usb_source / "COPYING", "libusb/COPYING"))
    # Include corresponding source, not merely an upstream URL that may disappear.
    for path in sorted(usb_source.rglob("*")):
        relative = path.relative_to(usb_source)
        if path.is_file() and ".git" not in relative.parts:
            materials.append((path, "libusb/source/" + relative.as_posix()))
    materials.append((repo / "native/lazer-audio/cmake/AndroidUac2.cmake", "libusb/AndroidUac2.cmake"))
    materials.append((repo / "native/lazer-audio/tools/build_android_dsd_ffmpeg.sh", "build_android_dsd_ffmpeg.sh"))
    materials.append((repo / "native/lazer-audio/src/exports_android.map", "exports_android.map"))
    for path, _ in materials:
        if not path.is_file() or path.stat().st_size == 0:
            raise SystemExit(f"Missing relinking material: {path}")
    staging = args.build / "relink-package"
    staging.mkdir(parents=True, exist_ok=True)
    target = {
        "arm64-v8a": "aarch64-linux-android26",
        "armeabi-v7a": "armv7a-linux-androideabi26",
        "x86_64": "x86_64-linux-android26",
    }[args.abi]
    relink = staging / "relink.sh"
    relink.write_text(f"""#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
: "${{ANDROID_NDK_HOME:?Set ANDROID_NDK_HOME to NDK 28.2.13676358}}"
case "$(uname -s)" in
  Linux*) host=linux-x86_64 ;;
  Darwin*) host=darwin-x86_64 ;;
  MINGW*|MSYS*) host=windows-x86_64 ;;
  *) echo 'Run on Linux, macOS or Git Bash on Windows' >&2; exit 2 ;;
esac
"$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$host/bin/clang++" \\
  --target={target} -shared -fPIC -static-libstdc++ \\
  -Wl,--exclude-libs,ALL,--version-script=exports_android.map \\
  -Wl,-z,defs,-z,max-page-size=16384,-soname,liblazer-audio.so \\
  objects/*.o -Wl,--start-group ffmpeg/lib/*.a libusb/lib/libusb-1.0.a -Wl,--end-group \\
  -laaudio -landroid -llog -lm -latomic -pthread -o liblazer-audio.so
""", encoding="utf-8", newline="\n")
    usb_cmake = staging / "CMakeLists.txt"
    usb_cmake.write_text('''cmake_minimum_required(VERSION 3.21)
project(lazer_libusb_rebuild LANGUAGES C)
set(LAZER_ANDROID_BUILD_ENGINE ON)
set(FETCHCONTENT_SOURCE_DIR_LIBUSB "${CMAKE_CURRENT_LIST_DIR}/source" CACHE PATH "")
include("${CMAKE_CURRENT_LIST_DIR}/AndroidUac2.cmake")
''', encoding="utf-8", newline="\n")
    materials.append((usb_cmake, "libusb/CMakeLists.txt"))
    readme = staging / "README.txt"
    readme.write_text(f"""Lazer Android Audio Engine: {args.abi}

This package provides the original FFmpeg and libusb static libraries and the
Lazer engine object files needed to replace either library and relink the engine.

libusb is LGPL-2.1-or-later (see libusb/COPYING), pinned to revision
87a55632db62c9bdc58cd31d3ccfa673f1bb017f. Original source archive:
https://codeload.github.com/libusb/libusb/tar.gz/87a55632db62c9bdc58cd31d3ccfa673f1bb017f
SHA256: 26733c3eee2475c062e14f80a62ece4b33ee3b33fc0c88b2758964412a42b7e0
Corresponding source and exact CMake source list/options are under libusb/.

1. For FFmpeg changes, use the included build_android_dsd_ffmpeg.sh (pinned
   revision and build options) with Android NDK 28.2.13676358.
   Replace ffmpeg/lib/*.a with your rebuilt same-ABI archives.
2. For libusb changes, edit libusb/source, then run from this directory:
   cmake -S libusb -B libusb-build -G Ninja \\
     -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake" \\
     -DANDROID_ABI={args.abi} -DANDROID_PLATFORM=android-26 -DCMAKE_BUILD_TYPE=Release
   cmake --build libusb-build --target usb-1.0
   cp libusb-build/libusb-1.0.a libusb/lib/libusb-1.0.a
3. Set ANDROID_NDK_HOME and run: bash relink.sh
4. In Lazer, open Settings > HiFi playback > Audio Engine > Import engine,
   select the generated liblazer-audio.so, then restart the app.

The unmodified archives are included so step 3 can also verify this package.
The app does not require the original library's signature or hash when
importing a compatible replacement.
""", encoding="utf-8", newline="\n")
    materials.extend(((relink, "relink.sh"), (readme, "README.txt")))
    manifest = staging / "SHA256.json"
    manifest.write_text(json.dumps({name: hashlib.sha256(path.read_bytes()).hexdigest()
                                   for path, name in materials}, indent=2) + "\n", encoding="utf-8")
    materials.append((manifest, "SHA256.json"))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tarfile.open(args.output, "w:gz") as archive:
        for path, name in materials:
            archive.add(path, arcname=name, recursive=False)
    checksum = hashlib.sha256(args.output.read_bytes()).hexdigest()
    Path(str(args.output) + ".sha256").write_text(
        f"{checksum}  {args.output.name}\n", encoding="ascii"
    )
    print(f"Packaged {len(objects)} engine objects, FFmpeg/libusb static libraries and libusb source: {args.output}")


if __name__ == "__main__":
    main()
