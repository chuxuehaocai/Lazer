#!/usr/bin/env bash
# Build the pinned DSD-capable FFmpeg revision as a small static iOS SDK.
#
# iOS cannot ship FFmpeg as loose dylibs signed after the fact, so this is a
# static SDK that is linked into the app binary together with the engine. The
# component list, the DSD demuxer/decoder requirements and the LGPL artifacts
# mirror build_android_dsd_ffmpeg.sh; only the toolchain and target differ.
#
# Must run on macOS with Xcode installed:
#   ./native/lazer-audio/tools/build_ios_dsd_ffmpeg.sh <install-prefix> [device|simulator]
set -euo pipefail

readonly FFMPEG_URL="https://github.com/FFmpeg/FFmpeg.git"
readonly FFMPEG_REVISION="c6e28adabac09745f3406ffbf3833b8ac7f3f46a"
readonly IOS_MIN_VERSION="15.0"
readonly PROFILE_REVISION="pcm-file-v2"

if [[ $# -lt 1 || $# -gt 2 || -z "$1" ]]; then
    echo "Usage: $0 <install-prefix> [device|simulator]" >&2
    exit 2
fi
if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "FFmpeg's iOS build needs Xcode, so it only runs on macOS." >&2
    exit 2
fi

platform="${2:-device}"
case "$platform" in
    device)
        sdk_name="iphoneos"
        ffmpeg_target_os="darwin"
        ;;
    simulator)
        sdk_name="iphonesimulator"
        ffmpeg_target_os="darwin"
        ;;
    *)
        echo "Platform must be 'device' or 'simulator', not '$platform'." >&2
        exit 2
        ;;
esac

sdk_path="$(xcrun --sdk "$sdk_name" --show-sdk-path)"
if [[ ! -d "$sdk_path" ]]; then
    echo "No $sdk_name SDK found; run xcode-select or install Xcode." >&2
    exit 2
fi
clang="$(xcrun --sdk "$sdk_name" -f clang)"
ar_tool="$(xcrun -f ar)"
ranlib_tool="$(xcrun -f ranlib)"
nm_tool="$(xcrun -f nm)"
strip_tool="$(xcrun -f strip)"

prefix_parent="$(dirname "$1")"
mkdir -p "$prefix_parent"
prefix="$(cd "$prefix_parent" && pwd)/$(basename "$1")"
ffmpeg_lib="$prefix/lib"
if [[ -f "$ffmpeg_lib/libavformat.a" &&
    -f "$ffmpeg_lib/libavcodec.a" &&
    -f "$ffmpeg_lib/libavutil.a" &&
    -f "$ffmpeg_lib/libswresample.a" &&
    -f "$prefix/share/lazer-ffmpeg/PROFILE.txt" ]] &&
    grep -Fxq "$FFMPEG_REVISION ios $platform $PROFILE_REVISION" \
        "$prefix/share/lazer-ffmpeg/PROFILE.txt"; then
    echo "Using the existing iOS FFmpeg static SDK at $prefix."
    exit 0
fi

work_root="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/lazer-ffmpeg-ios-${platform}-${FFMPEG_REVISION:0:12}"
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

# FFmpeg's darwin target adds the platform flags itself; the target triple is
# what makes it an iOS build. `xcrun -f clang` only prints a path and sets no
# SDKROOT, so without the triple the driver still thinks it is building for
# macOS and rejects every iOS probe.
target_triple="arm64-apple-ios${IOS_MIN_VERSION}"
if [[ "$platform" == "simulator" ]]; then
    target_triple="arm64-apple-ios${IOS_MIN_VERSION}-simulator"
fi
# One flag array is the single source of truth: FFmpeg gets it as a --cc string
# (`$cc` unquoted), while this script's own probe must not quote it as one word.
cc_flags=(-target "$target_triple" -isysroot "$sdk_path")
cc="$clang ${cc_flags[*]}"

# Fail before configure's first opaque "C compiler test failed" with the
# compiler's own stderr.
probe_root="$work_root/probe"
rm -rf "$probe_root" && mkdir -p "$probe_root"
printf 'int main(void) { return 0; }\n' > "$probe_root/probe.c"
if ! "$clang" "${cc_flags[@]}" -o "$probe_root/probe" "$probe_root/probe.c" \
    2> "$probe_root/probe.err"; then
    cat "$probe_root/probe.err" >&2
    echo "The iOS clang toolchain cannot link a test binary for $platform." >&2
    exit 1
fi

configure_args=(
    "--prefix=$prefix"
    "--libdir=$prefix/lib"
    "--incdir=$prefix/include"
    "--pkgconfigdir=$prefix/lib/pkgconfig"
    --enable-cross-compile
    "--target-os=$ffmpeg_target_os"
    --arch=aarch64
    # `arm64` is an *arch* alias, not a CPU name: as --cpu it becomes
    # -march=arm64, which clang rejects for an aarch64 target and which failed
    # FFmpeg's own compiler sanity check. `generic` adds no CPU flag at all and
    # lets the target triple pick the codegen.
    --cpu=generic
    "--cc=$cc"
    "--cxx=$cc"
    "--as=$cc"
    "--ar=$ar_tool"
    "--ranlib=$ranlib_tool"
    "--nm=$nm_tool"
    "--strip=$strip_tool"
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
    --enable-protocol=file
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
    --enable-demuxer=aac,mp3,mov,flac,ogg,wav,matroska,ape,asf,wv
    --enable-decoder=aac,mp3,mp3float,flac,vorbis,opus,alac,ape,wmav1,wmav2,wmalossless,wavpack
    '--enable-decoder=pcm*'
    --enable-parser=aac,aac_latm,mpegaudio,flac,vorbis,opus
)

cd "$source_dir"
printf 'FFmpeg revision: %s\nTarget: iOS %s, arm64, minimum %s\nSDK: %s\nConfigure options: %s\n' \
    "$FFMPEG_REVISION" "$platform" "$IOS_MIN_VERSION" "$sdk_path" \
    "${configure_args[*]}" | tee "$work_root/build-info.txt"
# configure's own "C compiler test failed" names no reason; the actual failing
# command and its stderr are in ffbuild/config.log.
if ! ./configure "${configure_args[@]}" 2>&1 | tee "$work_root/configure.log"; then
    echo '=== configure failed; tail of ffbuild/config.log ===' >&2
    tail -120 ffbuild/config.log >&2 || true
    exit 1
fi

# DSF has its own demuxer, while DFF (including DST-in-DFF) is handled by IFF.
# Keep this explicit: the decoder can link successfully while DFF inputs remain
# unavailable if the required demuxer was omitted from this minimal build.
for component in CONFIG_DSF_DEMUXER CONFIG_IFF_DEMUXER CONFIG_MOV_DEMUXER \
    CONFIG_MP3_DEMUXER CONFIG_FLAC_DEMUXER CONFIG_OGG_DEMUXER CONFIG_WAV_DEMUXER \
    CONFIG_AAC_DECODER CONFIG_MP3FLOAT_DECODER CONFIG_FLAC_DECODER CONFIG_ALAC_DECODER \
    CONFIG_VORBIS_DECODER CONFIG_OPUS_DECODER CONFIG_PCM_S16LE_DECODER CONFIG_FILE_PROTOCOL; do
    if ! grep -qE "^#define ${component} 1$" config_components.h; then
        echo "The iOS FFmpeg configuration is missing required $component." >&2
        exit 1
    fi
done

make -j"${FFMPEG_BUILD_JOBS:-4}"
make install

for component in avformat avcodec avutil swresample; do
    if [[ ! -f "$prefix/lib/lib$component.a" ]]; then
        echo "The iOS FFmpeg SDK is missing lib$component.a under $prefix/lib." >&2
        exit 1
    fi
    if compgen -G "$prefix/lib/lib$component.*dylib" >/dev/null; then
        echo "The iOS FFmpeg SDK must be static; found a shared lib$component." >&2
        exit 1
    fi
    if ! lipo -info "$prefix/lib/lib$component.a" | grep -q "arm64"; then
        echo "lib$component.a is not an arm64 archive." >&2
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

printf '%s ios %s %s\n' "$FFMPEG_REVISION" "$platform" "$PROFILE_REVISION" \
    > "$license_dir/PROFILE.txt"

printf 'Installed static iOS FFmpeg SDK at %s\n' "$prefix"
