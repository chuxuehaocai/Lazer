#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:?Set ANDROID_HOME}}"
ndk_version="${LAZER_ANDROID_NDK_VERSION:-28.2.13676358}"
ndk="$sdk/ndk/$ndk_version"
test -f "$ndk/build/cmake/android.toolchain.cmake"
case "$(uname -s)" in
  Linux*) host=linux-x86_64 ;;
  Darwin*) host=darwin-x86_64 ;;
  *) echo "Run the Android build helper on Linux or macOS" >&2; exit 2 ;;
esac
strip="$ndk/toolchains/llvm/prebuilt/$host/bin/llvm-strip"

for abi in arm64-v8a x86_64; do
  prefix="$repo/build/android-ffmpeg/$abi"
  bash "$repo/native/lazer-audio/tools/build_android_dsd_ffmpeg.sh" "$prefix" "$ndk" "$abi"
  output="$repo/build/android-audio/$abi"
  cmake -S "$repo/native" -B "$output" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$ndk/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI="$abi" -DANDROID_PLATFORM=android-26 -DANDROID_STL=c++_static \
    -DCMAKE_BUILD_TYPE=Release -DLAZER_FFMPEG_ROOT="$prefix" \
    -DCMAKE_SHARED_LINKER_FLAGS=-Wl,-z,max-page-size=16384
  cmake --build "$output" --target lazer-audio lazer-audio-bridge --parallel "${FFMPEG_BUILD_JOBS:-4}"
  libraries="$repo/android/app/src/main/jniLibs/$abi"
  licenses="$repo/android/app/src/main/assets/licenses/lazer-ffmpeg/$abi"
  mkdir -p "$libraries" "$licenses"
  cp "$output/lazer-audio/liblazer-audio.so" "$libraries/"
  cp "$output/lazer-audio-bridge/liblazer-audio-bridge.so" "$libraries/"
  "$strip" --strip-unneeded "$libraries/liblazer-audio.so" "$libraries/liblazer-audio-bridge.so"
  python3 "$repo/ci/verify-android-audio.py" --directory "$libraries" --abi "$abi"
  cp "$prefix/share/lazer-ffmpeg/COPYING.LGPLv2.1" "$licenses/"
  cp "$prefix/share/lazer-ffmpeg/BUILDINFO.txt" "$licenses/"
  python3 "$repo/ci/package-android-audio.py" --build "$output" --ffmpeg "$prefix" \
    --abi "$abi" --output "$repo/dist/Lazer-Android-Audio-Relink-$abi.tar.gz"
done
