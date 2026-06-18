#!/bin/bash
# Build a distributable GenieLM.dmg: bundle llama.cpp, Developer ID sign +
# hardened runtime, notarize (if a notary profile exists), and make a DMG.
set -euo pipefail
cd "$(dirname "$0")"

APP="GenieLM.app"
ID="Developer ID Application: Bharath Kumar Adinarayan (XMRV84UYRD)"
TEAM="XMRV84UYRD"
ENT="packaging/entitlements.plist"
NOTARY_PROFILE="${NOTARY_PROFILE:-genielm-notary}"

echo "1/7  Build app"
./build.sh >/dev/null

echo "2/7  Bundle llama-server + dylibs"
rm -rf "$APP/Contents/Helpers" "$APP/Contents/libs"
mkdir -p "$APP/Contents/Helpers" "$APP/Contents/libs"
cp "$(command -v llama-server)" "$APP/Contents/Helpers/llama-server"
dylibbundler -of -cd -b -i /usr/lib -i /System/Library \
  -x "$APP/Contents/Helpers/llama-server" \
  -d "$APP/Contents/libs" \
  -p "@executable_path/../libs/" \
  -s /opt/homebrew/opt/llama.cpp/lib \
  -s /opt/homebrew/opt/ggml/lib \
  -s /opt/homebrew/lib >/dev/null

echo "3/7  Sign bundled dylibs"
find "$APP/Contents/libs" -name "*.dylib" -print0 | while IFS= read -r -d '' f; do
  codesign --force --timestamp --options runtime -s "$ID" "$f"
done

echo "4/7  Sign llama-server helper"
codesign --force --timestamp --options runtime --entitlements "$ENT" -s "$ID" "$APP/Contents/Helpers/llama-server"

echo "5/7  Sign the app"
codesign --force --timestamp --options runtime --entitlements "$ENT" -s "$ID" "$APP/Contents/MacOS/GenieLM"
codesign --force --timestamp --options runtime --entitlements "$ENT" -s "$ID" "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "6/7  Notarize"
if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  ditto -c -k --keepParent "$APP" /tmp/GenieLM.zip
  xcrun notarytool submit /tmp/GenieLM.zip --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  echo "      notarized + stapled"
else
  echo "      SKIPPED — no notary profile '$NOTARY_PROFILE'. Create it once with:"
  echo "      xcrun notarytool store-credentials $NOTARY_PROFILE \\"
  echo "        --apple-id <your-apple-id> --team-id $TEAM --password <app-specific-password>"
fi

echo "7/7  DMG"
rm -f GenieLM.dmg
create-dmg --volname "GenieLM" --window-size 520 360 --icon-size 96 \
  --icon "GenieLM.app" 130 180 --app-drop-link 390 180 \
  GenieLM.dmg "$APP" >/dev/null 2>&1 || \
  hdiutil create -volname GenieLM -srcfolder "$APP" -ov -format UDZO GenieLM.dmg >/dev/null
echo "Done → GenieLM.dmg"
