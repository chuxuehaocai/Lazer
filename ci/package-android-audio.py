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
    parser.add_argument("--abi", choices=("arm64-v8a", "x86_64"), required=True)
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
    for name in ("COPYING.LGPLv2.1", "BUILDINFO.txt", "PROFILE.txt", "ffmpeg-source.tar.gz"):
        materials.append((args.ffmpeg / f"share/lazer-ffmpeg/{name}", f"ffmpeg/{name}"))
    materials.append((repo / "native/lazer-audio/src/exports_android.map", "exports_android.map"))
    materials.append((repo / "LICENSE", "LICENSE.Lazer"))
    for path, _ in materials:
        if not path.is_file() or path.stat().st_size == 0:
            raise SystemExit(f"Missing relinking material: {path}")
    staging = args.build / "relink-package"
    staging.mkdir(parents=True, exist_ok=True)
    target = "aarch64-linux-android26" if args.abi == "arm64-v8a" else "x86_64-linux-android26"
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
  objects/*.o -Wl,--start-group ffmpeg/lib/*.a -Wl,--end-group \\
  -laaudio -landroid -llog -lm -latomic -pthread -o liblazer-audio.so
""", encoding="utf-8", newline="\n")
    readme = staging / "README.txt"
    readme.write_text(f"""Lazer Android Audio Engine: {args.abi}

FFmpeg is statically linked under LGPL-2.1-or-later. This package provides its
exact corresponding source, build options, original archives and the Lazer
engine object files needed to replace FFmpeg and relink the engine.

1. Extract ffmpeg/ffmpeg-source.tar.gz and use the options in ffmpeg/BUILDINFO.txt
   with Android NDK 28.2.13676358 to rebuild FFmpeg, including your changes.
2. Replace ffmpeg/lib/*.a with your rebuilt same-ABI archives.
3. Set ANDROID_NDK_HOME and run: bash relink.sh
4. In Lazer, open Settings > HiFi playback > Audio Engine > Import engine,
   select the generated liblazer-audio.so, then restart the app.

The unmodified archives are included so step 3 can also verify this package.
Lazer's MIT license and the FFmpeg LGPL license are included. FFmpeg source
modification and reverse engineering for debugging those modifications are
permitted by the applicable LGPL terms. The app does not require the original
library's signature or hash when importing a compatible replacement.
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
    print(f"Packaged {len(objects)} engine objects and FFmpeg source: {args.output}")


if __name__ == "__main__":
    main()
