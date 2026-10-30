#!/bin/bash
# Builds build/Feral.app, the Mac app. Open it with `open build/Feral.app`, or copy it to
# /Applications. It talks to feral-engine over the control link (127.0.0.1 port 9100 by default).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product Feral
BIN="$(swift build -c release --show-bin-path)/Feral"
APP="build/Feral.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/Feral"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Feral</string>
    <key>CFBundleDisplayName</key><string>Feral</string>
    <key>CFBundleIdentifier</key><string>local.feral.app</string>
    <key>CFBundleExecutable</key><string>Feral</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.3</string>
    <key>CFBundleVersion</key><string>$(git rev-list --count HEAD 2>/dev/null || echo 1)</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSLocalNetworkUsageDescription</key><string>Feral connects to the Feral engine on this Mac or on another Mac on the network.</string>
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key><string>local.feral.show</string>
            <key>UTTypeDescription</key><string>Feral show</string>
            <key>UTTypeConformsTo</key><array><string>com.apple.package</string></array>
            <key>UTTypeTagSpecification</key>
            <dict><key>public.filename-extension</key><array><string>feralshow</string></array></dict>
        </dict>
    </array>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"
