#!/usr/bin/env bash
# Builds the native audio engine for iOS and stages the static archives the app
# links against.
#
# iOS cannot copy a dylib into a signed bundle the way the desktop build does,
# so the engine, its reader bridge and FFmpeg are built as static archives,
# linked into the app binary and reached through DynamicLibrary.process().
#
#   bash ci/build-ios-audio.sh [device|simulator]
#
# Requires macOS with Xcode. Results land in build/ios-audio/<platform>/.
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
platform="${1:-device}"
case "$platform" in
    device) sdk_name="iphoneos" ;;
    simulator) sdk_name="iphonesimulator" ;;
    *)
        echo "Usage: $0 [device|simulator]" >&2
        exit 2
        ;;
esac
if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "The iOS engine build needs macOS and Xcode." >&2
    exit 2
fi

ffmpeg_root="${LAZER_IOS_FFMPEG_ROOT:-$repo/build/ios-ffmpeg/$platform}"
build="$repo/build/ios-audio/$platform"
stage="$build/stage"
rm -rf "$build/cmake" "$stage"
mkdir -p "$stage/lib" "$stage/licenses"

bash "$repo/native/lazer-audio/tools/build_ios_dsd_ffmpeg.sh" "$ffmpeg_root" "$platform"

cmake -S "$repo/native" -B "$build/cmake" -G Xcode \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
    -DCMAKE_OSX_SYSROOT="$(xcrun --sdk "$sdk_name" --show-sdk-path)" \
    -DLAZER_FFMPEG_ROOT="$ffmpeg_root" \
    -DLAZER_AUDIO_REQUIRE_ENGINE=ON \
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO \
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED=NO
cmake --build "$build/cmake" --config Release --target lazer-audio lazer-audio-bridge

engine="$(find "$build/cmake" -name 'liblazer-audio.a' -path '*Release*' -print -quit)"
bridge="$(find "$build/cmake" -name 'liblazer-audio-bridge.a' -path '*Release*' -print -quit)"
if [[ -z "$engine" || -z "$bridge" ]]; then
    echo "::error::the iOS engine archives were not produced" >&2
    exit 1
fi
cp "$engine" "$bridge" "$stage/lib/"
for component in avformat avcodec avutil swresample; do
    cp "$ffmpeg_root/lib/lib$component.a" "$stage/lib/"
done
cp "$ffmpeg_root/share/lazer-ffmpeg/"* "$stage/licenses/"

# Every archive must be an arm64 slice, and the engine must export the ABI the
# Dart loader checks before it will ever pick the native path.
for archive in "$stage/lib"/*.a; do
    if ! lipo -info "$archive" | grep -q 'arm64'; then
        echo "::error::$archive is not an arm64 archive" >&2
        exit 1
    fi
done

symbols="$(nm -g --defined-only "$stage/lib/liblazer-audio.a" |
    awk '{print $NF}' | sed 's/^_//' | sort -u)"
missing=0
for symbol in \
    lazer_audio_abi_version \
    lazer_audio_create \
    lazer_audio_destroy \
    lazer_audio_open_file_utf8 \
    lazer_audio_open_reader \
    lazer_audio_queue_reader \
    lazer_audio_clear_queued_reader \
    lazer_audio_play \
    lazer_audio_pause \
    lazer_audio_stop \
    lazer_audio_seek \
    lazer_audio_set_volume \
    lazer_audio_set_dsp \
    lazer_audio_set_device \
    lazer_audio_snapshot \
    lazer_audio_stream_info \
    lazer_audio_last_error \
    lazer_audio_build_information; do
    if ! grep -qx "$symbol" <<<"$symbols"; then
        echo "::error::$symbol is missing from the iOS engine archive" >&2
        missing=1
    fi
done
if [[ "$missing" -ne 0 ]]; then
    exit 1
fi

bridge_symbols="$(nm -g --defined-only "$stage/lib/liblazer-audio-bridge.a" |
    awk '{print $NF}' | sed 's/^_//' | sort -u)"
missing=0
for symbol in lazer_bridge_reader_create lazer_bridge_reader_read \
    lazer_bridge_reader_notify lazer_bridge_reader_finish \
    lazer_bridge_reader_destroy; do
    if ! grep -qx "$symbol" <<<"$bridge_symbols"; then
        echo "::error::$symbol is missing from the iOS reader bridge archive" >&2
        missing=1
    fi
done
if [[ "$missing" -ne 0 ]]; then
    exit 1
fi

{
    printf 'platform=%s\n' "$platform"
    printf 'sdk=%s\n' "$(xcrun --sdk "$sdk_name" --show-sdk-path)"
    printf 'xcode=%s\n' "$(xcodebuild -version | head -n 1)"
    for archive in "$stage/lib"/*.a; do
        printf '%s %s\n' "$(shasum -a 256 "$archive" | awk '{print $1}')" "${archive##*/}"
    done
} > "$stage/manifest.txt"

printf 'Staged the iOS engine for %s:\n' "$platform"
ls -la "$stage/lib"
