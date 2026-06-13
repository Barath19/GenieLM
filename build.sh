#!/bin/bash
# Builds ShakeSight and wraps it into a .app bundle so macOS treats it as a
# proper menu-bar agent and attaches Screen Recording permission to the bundle.
set -euo pipefail
cd "$(dirname "$0")"

APP="ShakeSight.app"
BIN_NAME="ShakeSight"

echo "Compiling (release)..."
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/$BIN_NAME"

echo "Assembling $APP..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH" "$APP/Contents/MacOS/$BIN_NAME"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>ShakeSight</string>
    <key>CFBundleIdentifier</key>
    <string>com.barath.shakesight</string>
    <key>CFBundleName</key>
    <string>ShakeSight</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSScreenCaptureUsageDescription</key>
    <string>ShakeSight captures your screen to analyze it when you shake the mouse.</string>
</dict>
</plist>
PLIST

# Ad-hoc sign so the permission grant sticks to a stable identity.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "Built $APP"
echo "Run it with:  open $APP   (or ./$APP/Contents/MacOS/ShakeSight for logs)"
