#!/usr/bin/env bash
# Build the pinned upstream FFmpeg revision that exposes raw DSD through its public API.
# Do not replace this with the host package manager: stable distro/Homebrew packages can lack DSD.
set -euo pipefail

readonly FFmpeg_URL="https://github.com/FFmpeg/FFmpeg.git"
readonly FFmpeg_REVISION="c6e28adabac09745f3406ffbf3833b8ac7f3f46a"

if [[ $# -ne 1 || -z "$1" ]]; then
    echo "Usage: $0 <install-prefix>" >&2
    exit 2
fi

prefix="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
work_root="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/lazer-ffmpeg-${FFmpeg_REVISION:0:12}"
source_dir="$work_root/source"

mkdir -p "$work_root" "$prefix"
if [[ ! -d "$source_dir/.git" ]]; then
    mkdir -p "$source_dir"
    git -C "$source_dir" init
    git -C "$source_dir" remote add origin "$FFmpeg_URL"
fi

git -C "$source_dir" fetch --no-tags --depth=1 origin "$FFmpeg_REVISION"
resolved_revision="$(git -C "$source_dir" rev-parse FETCH_HEAD^{commit})"
if [[ "$resolved_revision" != "$FFmpeg_REVISION" ]]; then
    echo "Fetched FFmpeg revision $resolved_revision, expected $FFmpeg_REVISION" >&2
    exit 1
fi
git -C "$source_dir" checkout --force --detach "$resolved_revision"

cd "$source_dir"
configure_args=(
    "--prefix=$prefix"
    "--libdir=$prefix/lib"
    "--shlibdir=$prefix/lib"
    "--incdir=$prefix/include"
    --enable-shared
    --disable-static
    --enable-pic
    --disable-programs
    --disable-doc
    --disable-debug
    --disable-autodetect
    --disable-avdevice
    --disable-avfilter
    --disable-swscale
)
# Give FFmpeg dylibs a location-independent install name. The desktop bundle copies these shared
# libraries beside liblazer-audio.dylib, whose @loader_path runpath then resolves @rpath entries.
# Keep Linux's normal SONAME/RPATH behavior unchanged.
if [[ "$(uname -s)" == Darwin ]]; then
    configure_args+=("--install-name-dir=@rpath")
fi
printf 'FFmpeg revision: %s\nConfigure options: %s\n' \
    "$FFmpeg_REVISION" "${configure_args[*]}" | tee "$work_root/build-info.txt"
./configure "${configure_args[@]}" 2>&1 | tee "$work_root/configure.log"
make -j"${FFMPEG_BUILD_JOBS:-2}"
make install

# The engine and FFmpeg dylibs ship side by side. Preserve their @rpath install IDs while giving
# each FFmpeg image a relative runpath for its own transitive @rpath dependencies.
if [[ "$(uname -s)" == Darwin ]]; then
    shopt -s nullglob
    runtime_dylibs=("$prefix"/lib/libav*.dylib "$prefix"/lib/libswresample*.dylib)
    if ((${#runtime_dylibs[@]} == 0)); then
        echo "The macOS FFmpeg SDK did not install its shared runtime dylibs." >&2
        exit 1
    fi
    for dylib in "${runtime_dylibs[@]}"; do
        if ! otool -l "$dylib" | grep -Fq 'path @loader_path ('; then
            install_name_tool -add_rpath @loader_path "$dylib"
        fi
    done
fi

# Keep the LGPL notice and the precise corresponding source revision beside the installed SDK.
license_dir="$prefix/share/lazer-ffmpeg"
mkdir -p "$license_dir"
install -m 0644 COPYING.LGPLv2.1 "$license_dir/COPYING.LGPLv2.1"
{
    cat "$work_root/build-info.txt"
    printf 'Source: https://github.com/FFmpeg/FFmpeg/tree/%s\n' "$FFmpeg_REVISION"
    printf 'License: LGPL-2.1-or-later (FFmpeg upstream default configure profile)\n'
} > "$license_dir/BUILDINFO.txt"

printf 'Installed FFmpeg %s at %s\n' \
    "$(grep -m1 '^#define FFMPEG_VERSION ' config.h | sed 's/.*"\(.*\)".*/\1/')" \
    "$prefix"
