#!/usr/bin/env bash
# Build the pinned DSD-capable FFmpeg revision as a small Android static SDK.
set -euo pipefail

readonly FFMPEG_URL="https://github.com/FFmpeg/FFmpeg.git"
readonly FFMPEG_REVISION="c6e28adabac09745f3406ffbf3833b8ac7f3f46a"
readonly NDK_REVISION="30.0.16248370"
readonly ANDROID_API="24"

if [[ $# -lt 1 || $# -gt 3 || -z "$1" ]]; then
    echo "Usage: $0 <install-prefix> [android-ndk-root] [arm64-v8a|x86_64]" >&2
    exit 2
fi

abi="${3:-arm64-v8a}"
case "$abi" in
    arm64-v8a)
        target="aarch64-linux-android"
        ffmpeg_arch="aarch64"
        ffmpeg_cpu="armv8-a"
        ;;
    x86_64)
        target="x86_64-linux-android"
        # FFmpeg's configure canonicalizes all x86 targets under arch=x86, then
        # detects the 64-bit sub-architecture from the Android clang target.
        ffmpeg_arch="x86"
        ffmpeg_cpu="x86-64"
        ;;
    *)
        echo "Unsupported Android ABI '$abi'; choose arm64-v8a or x86_64." >&2
        exit 2
        ;;
esac

prefix_parent="$(dirname "$1")"
mkdir -p "$prefix_parent"
prefix="$(cd "$prefix_parent" && pwd)/$(basename "$1")"
ffmpeg_lib="$prefix/lib"
if [[ -f "$ffmpeg_lib/libavformat.a" &&
    -f "$ffmpeg_lib/libavcodec.a" &&
    -f "$ffmpeg_lib/libavutil.a" &&
    -f "$ffmpeg_lib/libswresample.a" &&
    -f "$ffmpeg_lib/pkgconfig/libavformat.pc" ]]; then
    echo "Using the existing Android FFmpeg static SDK at $prefix."
    exit 0
fi

ndk_root="${2:-${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}}"
if [[ -z "$ndk_root" && -n "${ANDROID_HOME:-}" ]]; then
    ndk_root="$ANDROID_HOME/ndk/$NDK_REVISION"
fi
if [[ -z "$ndk_root" || ! -f "$ndk_root/source.properties" ]]; then
    echo "Pass the Android NDK r30 root as the second argument or ANDROID_NDK_HOME." >&2
    exit 2
fi
if ! grep -Fxq "Pkg.Revision = $NDK_REVISION" "$ndk_root/source.properties"; then
    echo "Expected Android NDK $NDK_REVISION (r30) at $ndk_root." >&2
    exit 2
fi

case "$(uname -s)" in
    Linux*) host_tag="linux-x86_64" ;;
    Darwin*) host_tag="darwin-x86_64" ;;
    *)
        echo "FFmpeg's Autoconf build must run on Linux or macOS; use Linux/WSL2 from Windows." >&2
        exit 2
        ;;
esac

toolchain="$ndk_root/toolchains/llvm/prebuilt/$host_tag"
for tool in clang clang++ llvm-ar llvm-ranlib llvm-nm llvm-strip; do
    if [[ ! -x "$toolchain/bin/$tool" ]]; then
        echo "Missing NDK tool: $toolchain/bin/$tool" >&2
        exit 2
    fi
done

work_root="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/lazer-ffmpeg-android-${abi}-${FFMPEG_REVISION:0:12}"
source_dir="$work_root/source"
mkdir -p "$work_root" "$prefix"
if [[ ! -d "$source_dir/.git" ]]; then
    mkdir -p "$source_dir"
    git -C "$source_dir" init
    git -C "$source_dir" remote add origin "$FFMPEG_URL"
fi

git -C "$source_dir" fetch --no-tags --depth=1 origin "$FFMPEG_REVISION"
resolved_revision="$(git -C "$source_dir" rev-parse 'FETCH_HEAD^{commit}')"
if [[ "$resolved_revision" != "$FFMPEG_REVISION" ]]; then
    echo "Fetched FFmpeg revision $resolved_revision, expected $FFMPEG_REVISION" >&2
    exit 1
fi
git -C "$source_dir" checkout --force --detach "$resolved_revision"

cc="$toolchain/bin/clang --target=$target$ANDROID_API"
cxx="$toolchain/bin/clang++ --target=$target$ANDROID_API"
configure_args=(
    "--prefix=$prefix"
    "--libdir=$prefix/lib"
    "--incdir=$prefix/include"
    "--pkgconfigdir=$prefix/lib/pkgconfig"
    --enable-cross-compile
    --target-os=android
    "--arch=$ffmpeg_arch"
    "--cpu=$ffmpeg_cpu"
    "--cc=$cc"
    "--cxx=$cxx"
    "--as=$cc"
    "--ar=$toolchain/bin/llvm-ar"
    "--ranlib=$toolchain/bin/llvm-ranlib"
    "--nm=$toolchain/bin/llvm-nm"
    "--strip=$toolchain/bin/llvm-strip"
    --disable-autodetect
    --disable-everything
    --enable-static
    --disable-shared
    --enable-pic
    --disable-programs
    --disable-doc
    --disable-debug
    --disable-avdevice
    --disable-avfilter
    --disable-swscale
    --disable-network
    --disable-protocols
    --disable-devices
    --disable-zlib
    --disable-bzlib
    --disable-lzma
    --enable-avformat
    --enable-avcodec
    --enable-avutil
    --enable-swresample
    --enable-demuxer=dsf
    --enable-demuxer=iff
    --enable-decoder=dsd_lsbf_planar,dsd_msbf_planar,dst
)

cd "$source_dir"
printf 'FFmpeg revision: %s\nNDK revision: %s\nTarget: %s, API %s\nConfigure options: %s\n' \
    "$FFMPEG_REVISION" "$NDK_REVISION" "$target ($abi)" "$ANDROID_API" \
    "${configure_args[*]}" | tee "$work_root/build-info.txt"
./configure "${configure_args[@]}" 2>&1 | tee "$work_root/configure.log"

# DSF has its own demuxer, while DFF (including DST-in-DFF) is handled by IFF.
# Keep this explicit: the decoder can link successfully while DFF inputs remain
# unavailable if the required demuxer was omitted from this minimal build.
for component in CONFIG_DSF_DEMUXER CONFIG_IFF_DEMUXER; do
    if ! grep -qE "^#define ${component} 1$" config_components.h; then
        echo "The Android FFmpeg configuration is missing required $component." >&2
        exit 1
    fi
done

make -j"${FFMPEG_BUILD_JOBS:-2}"
make install

for component in avformat avcodec avutil swresample; do
    if [[ ! -f "$prefix/lib/lib$component.a" ]]; then
        echo "The Android FFmpeg SDK is missing lib$component.a under $prefix/lib." >&2
        exit 1
    fi
    if compgen -G "$prefix/lib/lib$component.so*" >/dev/null; then
        echo "The Android FFmpeg SDK must be static; found a shared lib$component under $prefix/lib." >&2
        exit 1
    fi
done

license_dir="$prefix/share/lazer-ffmpeg"
mkdir -p "$license_dir"
install -m 0644 COPYING.LGPLv2.1 "$license_dir/COPYING.LGPLv2.1"
{
    cat "$work_root/build-info.txt"
    printf 'Source: https://github.com/FFmpeg/FFmpeg/tree/%s\n' "$FFMPEG_REVISION"
    printf 'License: LGPL-2.1-or-later (FFmpeg upstream default configure profile)\n'
} > "$license_dir/BUILDINFO.txt"

printf 'Installed static Android FFmpeg SDK at %s\n' "$prefix"
