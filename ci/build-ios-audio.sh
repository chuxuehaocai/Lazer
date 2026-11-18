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
mkdir -p "$stage/lib"

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

# The same gate used by Runner checks all reader symbols, not only playback's
# minimal subset, and distinguishes device arm64 from Simulator arm64 objects.
python3 "$repo/ci/verify-ios-audio.py" --archive "$stage/lib" --platform "$platform"

{
    printf 'platform=%s\n' "$platform"
    printf 'sdk=%s\n' "$(xcrun --sdk "$sdk_name" --show-sdk-path)"
    # Consume the complete output: head can close the pipe while xcodebuild is
    # still writing its build number, provoking an NSFileHandle exception.
    printf 'xcode=%s\n' "$(xcodebuild -version | sed -n '1p')"
    for archive in "$stage/lib"/*.a; do
        printf '%s %s\n' "$(shasum -a 256 "$archive" | awk '{print $1}')" "${archive##*/}"
    done
} > "$stage/manifest.txt"

printf 'Staged the iOS engine for %s:\n' "$platform"
ls -la "$stage/lib"
