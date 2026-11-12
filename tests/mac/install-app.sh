#!/bin/bash
# Installs the app from the DMG the way a person does (drag to Applications), then
# checks the installed copy: version, both CPU slices, signature, notarization,
# the entitlements and Info.plist keys the mic, paste and sign-in need, and the
# signed key listener helper.
set -uo pipefail
source "$(dirname "$0")/lib.sh"

mnt="$RUNNER_TEMP/dmg"
if hdiutil verify "$DMG" > "$OUT/hdiutil-verify.txt" 2>&1; then
  record PASS "DMG checksum (hdiutil verify)" "$(basename "$DMG")"
else
  record FAIL "DMG checksum (hdiutil verify)" "$(tail -n 1 "$OUT/hdiutil-verify.txt")"
fi
mkdir -p "$mnt"
if ! hdiutil attach -nobrowse -readonly -mountpoint "$mnt" "$DMG" > /dev/null; then
  record FAIL "DMG opens" "hdiutil attach failed"
  exit 1
fi
ls -la "$mnt" | tee "$OUT/dmg-contents.txt"
dmg_app=$(find "$mnt" -maxdepth 1 -name '*.app' | head -n 1)
if [ -z "$dmg_app" ]; then
  record FAIL "DMG contains the app" "no .app at the top of the DMG"
  hdiutil detach "$mnt" -quiet
  exit 1
fi
if [ -L "$mnt/Applications" ]; then record PASS "DMG has the Applications shortcut" ""
else record FAIL "DMG has the Applications shortcut" "no Applications link to drag onto"; fi

APP_NAME=$(basename "$dmg_app")
APP="/Applications/$APP_NAME"
sudo rm -rf "$APP"
ditto "$dmg_app" "$APP"
hdiutil detach "$mnt" -quiet
record PASS "Installed to /Applications" "$APP_NAME"

plist="$APP/Contents/Info"
exe=$(defaults read "$plist" CFBundleExecutable)
{
  echo "APP=$APP"
  echo "APP_PROCESS=$exe"
  echo "BUNDLE_ID=$(defaults read "$plist" CFBundleIdentifier)"
} >> "$GITHUB_ENV"

v=$(defaults read "$plist" CFBundleShortVersionString)
if [ "$v" = "$VERSION" ]; then record PASS "App version" "$v"
else record FAIL "App version" "app says $v, release is $VERSION"; fi

archs=$(lipo -archs "$APP/Contents/MacOS/$exe" | tr ' ' '\n' | sort | xargs)
if [ "$archs" = "arm64 x86_64" ]; then record PASS "Universal binary" "$archs"
else record FAIL "Universal binary" "only $archs: Macs with the other CPU can't run the DMG"; fi

check "Code signature (codesign --verify --deep --strict)" codesign --verify --deep --strict --verbose=2 "$APP"
check "Gatekeeper accepts it (spctl)" spctl --assess --type execute --verbose=2 "$APP"
check "Notarization ticket stapled" xcrun stapler validate "$APP"
team=$(codesign -dv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')
record INFO "Signing team" "${team:-none}"

codesign -d --entitlements - --xml "$APP" > "$OUT/entitlements.plist" 2>/dev/null || true
if grep -q 'com.apple.security.device.audio-input' "$OUT/entitlements.plist"; then
  record PASS "Microphone entitlement (hardened runtime)" "com.apple.security.device.audio-input"
else
  record FAIL "Microphone entitlement (hardened runtime)" "missing: a notarized app gets silence from the mic without it"
fi
if grep -q 'com.apple.security.automation.apple-events' "$OUT/entitlements.plist"; then
  record PASS "Apple Events entitlement" "needed for the System Events paste and app lookup"
else
  record FAIL "Apple Events entitlement" "missing: osascript to System Events is blocked under hardened runtime"
fi

for key in NSMicrophoneUsageDescription NSAppleEventsUsageDescription; do
  if defaults read "$plist" "$key" > /dev/null 2>&1; then record PASS "Info.plist $key" "$(defaults read "$plist" "$key" | cut -c1-80)"
  else record FAIL "Info.plist $key" "missing: macOS refuses the request without a reason string"; fi
done
if plutil -extract CFBundleURLTypes xml1 -o - "$plist.plist" 2>/dev/null | grep -q '<string>blipai</string>'; then
  record PASS "blipai:// URL scheme declared" "sign-in returns to the app through it"
else
  record FAIL "blipai:// URL scheme declared" "sign-in from the browser can't reach the app"
fi

key_server=$(find "$APP" -name MacKeyServer -type f | head -n 1)
if [ -z "$key_server" ]; then
  record FAIL "Key listener helper (MacKeyServer)" "not in the bundle: Fn push-to-talk can't work"
else
  echo "KEY_SERVER=$key_server" >> "$GITHUB_ENV"
  if [ -x "$key_server" ] && codesign --verify --strict "$key_server" 2>/dev/null; then
    record PASS "Key listener helper (MacKeyServer)" "executable, signed, $(lipo -archs "$key_server")"
  else
    record FAIL "Key listener helper (MacKeyServer)" "not executable or not validly signed"
  fi
fi
exit 0
