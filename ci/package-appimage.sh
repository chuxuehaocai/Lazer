#!/usr/bin/env bash
set -euo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo"
arch=${1:-$(uname -m)}
case "$arch" in
  x86_64)
    bundle_arch=x64
    tool_sha=c20cd71e3a4e3b80c3483cef793cda3f4e990aca14014d23c544ca3ce1270b4d
    ;;
  aarch64)
    bundle_arch=arm64
    tool_sha=620095110d693282b8ebeb244a95b5e911cf8f65f76c88b4b47d16ae6346fcff
    ;;
  *) echo "Unsupported architecture: $arch" >&2; exit 1 ;;
esac
test "$(uname -m)" = "$arch"
bundle="build/linux/$bundle_arch/release/bundle"
test -x "$bundle/lazer_nextgen"
test -d "$bundle/data"
test -d "$bundle/lib"
require_file() {
  if [[ ! -f "$1" ]]; then
    echo "Missing required file in the Flutter bundle: $1" >&2
    exit 1
  fi
}
require_file "$bundle/lib/liblazer-audio.so"
require_file "$bundle/lib/liblazer-audio-bridge.so"
for component in avcodec avformat avutil swresample; do
  if ! compgen -G "$bundle/lib/lib${component}.so*" > /dev/null; then
    echo "Missing FFmpeg runtime library in the Flutter bundle: $component" >&2
    exit 1
  fi
done

tools=$(mktemp -d)
trap 'rm -rf -- "$tools"' EXIT
linuxdeploy_url="https://github.com/linuxdeploy/linuxdeploy/releases/download/1-alpha-20251107-1/linuxdeploy-$arch.AppImage"
case "$arch" in
  x86_64) linuxdeploy_asset=313839329 ;;
  aarch64) linuxdeploy_asset=313839294 ;;
esac
# The release-assets CDN has repeatedly answered 504 for large assets from
# hosted runners. The API asset endpoint serves the same verified file through
# a different redirect and works when that CDN path does not.
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  if ! curl --fail --location --retry 6 --retry-all-errors --retry-delay 3 \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H 'Accept: application/octet-stream' \
    "https://api.github.com/repos/linuxdeploy/linuxdeploy/releases/assets/$linuxdeploy_asset" \
    -o "$tools/linuxdeploy-$arch.AppImage"; then
    rm -f -- "$tools/linuxdeploy-$arch.AppImage"
    echo 'API asset download failed; falling back to the release CDN' >&2
  fi
fi
if [[ ! -s "$tools/linuxdeploy-$arch.AppImage" ]]; then
  curl --fail --location --retry 10 --retry-all-errors --retry-delay 3 \
    "$linuxdeploy_url" -o "$tools/linuxdeploy-$arch.AppImage"
fi
echo "$tool_sha  linuxdeploy-$arch.AppImage" |
  (cd "$tools" && sha256sum --check -)
curl --fail --location --retry 10 --retry-all-errors --retry-delay 3 \
  https://raw.githubusercontent.com/linuxdeploy/linuxdeploy-plugin-gtk/7a3fbc31a9e5075073ff8790f26effbac5f84453/linuxdeploy-plugin-gtk.sh \
  -o "$tools/linuxdeploy-plugin-gtk.sh"

# appimagetool otherwise downloads its runtime from the GitHub release CDN on
# every package run; that asset intermittently returns 504 on CI. Use the
# type-2 runtime already embedded in the verified linuxdeploy AppImage.
runtime="$tools/runtime-$arch"
linuxdeploy="$tools/linuxdeploy-$arch.AppImage"
runtime_offset="$(APPIMAGE_EXTRACT_AND_RUN=1 "$linuxdeploy" --appimage-offset)"
[[ "$runtime_offset" =~ ^[1-9][0-9]*$ ]] || {
  echo "Could not determine the linuxdeploy AppImage runtime offset: $runtime_offset" >&2
  exit 1
}
linuxdeploy_size="$(stat -c '%s' "$linuxdeploy")"
(( runtime_offset < linuxdeploy_size )) || {
  echo "The linuxdeploy runtime offset exceeds the AppImage size" >&2
  exit 1
}
head -c "$runtime_offset" "$linuxdeploy" > "$runtime"
test -s "$runtime"
chmod 0444 "$runtime"
export LDAI_RUNTIME_FILE="$runtime"
chmod +x "$tools/"*.AppImage "$tools/"*.sh

# Retain Flutter's executable-relative data/ and lib/ directories. libmpv is
# loaded via FFI, so linuxdeploy cannot discover it through DT_NEEDED alone.
appdir="$repo/build/appimage/$arch/Lazer.AppDir"
mkdir -p "$appdir/usr/bin" "$repo/dist"
cp -a "$bundle/." "$appdir/usr/bin/"
mpv=$(ldconfig -p | awk '/libmpv\.so\.[12] / && !found { print $NF; found=1 }')
test -n "$mpv"
export APPIMAGE_EXTRACT_AND_RUN=1
export DEPLOY_GTK_VERSION=3
filename="Lazer-Linux-$arch.AppImage"
export OUTPUT="$repo/dist/$filename"
export ARCH="$arch"
export PATH="$tools:$PATH"
"$tools/linuxdeploy-$arch.AppImage" \
  --appdir "$appdir" \
  --executable "$appdir/usr/bin/lazer_nextgen" \
  --library "$mpv" \
  --desktop-file "$repo/ci/linux/lazer.desktop" \
  --icon-file "$repo/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_256.png" \
  --custom-apprun "$repo/ci/linux/AppRun" \
  --plugin gtk --output appimage
chmod +x "$OUTPUT"
find "$appdir/usr/lib" -name 'libmpv.so*' -print -quit | grep -q .
require_file "$appdir/usr/bin/lib/liblazer-audio.so"
require_file "$appdir/usr/bin/lib/liblazer-audio-bridge.so"
python3 ci/verify-package-contents.py "$appdir"
(cd dist && sha256sum "$filename" > "$filename.sha256")
