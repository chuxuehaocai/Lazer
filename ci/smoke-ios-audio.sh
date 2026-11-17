#!/usr/bin/env bash
# Real iOS Simulator playback using the Release static engine/FFmpeg/bridge.
# No Flutter dependency; errors and the device-driven clock remain in artifacts.
set -euo pipefail
if [[ "$(uname -s)" != Darwin ]]; then
    echo 'The iOS Simulator smoke test requires macOS and Xcode.' >&2
    exit 2
fi
repo="$(cd "$(dirname "$0")/.." && pwd)"
lib="$repo/build/ios-audio/simulator/stage/lib"
out="$repo/build/ios-audio-smoke"
app="$out/AudioSmoke.app"
bundle=dev.naominet.lazer.audiosmoke
mkdir -p "$app"
sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
xcrun --sdk iphonesimulator clang++ -target arm64-apple-ios15.0-simulator \
    -isysroot "$sdk" -std=c++20 -fobjc-arc -O2 \
    -I "$repo/native/lazer-audio/include" "$repo/ci/ios-audio-smoke.mm" \
    -Wl,-force_load,"$lib/liblazer-audio.a" \
    -Wl,-force_load,"$lib/liblazer-audio-bridge.a" \
    -L "$lib" -lavformat -lavcodec -lswresample -lavutil \
    -framework UIKit -framework AVFAudio -framework AudioToolbox \
    -framework CoreAudio -framework CoreFoundation -lc++ -Wl,-export_dynamic \
    -o "$app/AudioSmoke"
cat > "$app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>AudioSmoke</string>
<key>CFBundleIdentifier</key><string>dev.naominet.lazer.audiosmoke</string>
<key>CFBundleName</key><string>AudioSmoke</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>MinimumOSVersion</key><string>15.0</string>
<key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
<key>UIBackgroundModes</key><array><string>audio</string></array>
<key>UILaunchScreen</key><dict/>
</dict></plist>
PLIST
codesign --force --sign - "$app"

# Launch synchronously before starting the playback deadline. The runner owns
# only its newly created simulator and bounds both setup and cleanup commands.
python3 "$repo/ci/run-ios-audio-smoke.py" --app "$app" --out "$out" --bundle "$bundle"
