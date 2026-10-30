#!/bin/bash
# Builds build/FeralEngine.app: feral-engine inside a minimal app bundle, so macOS can ask once for
# audio input access and remember it for "Feral Engine" (a bare binary started by launchd cannot).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product feral-engine
BIN="$(swift build -c release --show-bin-path)/feral-engine"
APP="build/FeralEngine.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/feral-engine"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Feral Engine</string>
    <key>CFBundleDisplayName</key><string>Feral Engine</string>
    <key>CFBundleIdentifier</key><string>local.feral.engine</string>
    <key>CFBundleExecutable</key><string>feral-engine</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.2</string>
    <key>CFBundleVersion</key><string>$(git rev-list --count HEAD 2>/dev/null || echo 1)</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSBackgroundOnly</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>Feral Engine renders the audio inputs of your sound system's interface to its speakers.</string>
</dict>
</plist>
PLIST

# An ad-hoc signature gives the bundle a stable identity for the audio input permission. Each
# rebuild changes it, so macOS may ask again after an update.
codesign --force --sign - "$APP"
echo "Built $APP"
