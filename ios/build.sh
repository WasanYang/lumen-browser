#!/bin/bash
# Builds the iPhone/iPad app. Needs Xcode (used through DEVELOPER_DIR, so xcode-select can stay on the
# Command Line Tools) and XcodeGen (brew install xcodegen).
#   ./build.sh sim              build, install and open on the iPhone simulator (SIMULATOR="iPad Pro 11-inch (M5)" for iPad)
#   ./build.sh sim --selftest   same, then run the self-test in the simulator and print PASS/FAIL
#   ./build.sh device           build, install and open on the paired iPhone or iPad
#                               (DEVICE=iPad ./build.sh device picks the one whose name contains "iPad",
#                               or give its UDID; --no-launch installs without opening the app.
#                               Free Apple ID: the app stops opening after 7 days; renew.sh renews it)
set -euo pipefail
cd "$(dirname "$0")"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
bundle_id=io.github.wasanyang.lumen

# Resources that live elsewhere in the repo, gathered into Generated/ (not committed).
rm -rf Generated
mkdir -p Generated/Assets.xcassets/AppIcon.appiconset
cp ../shared/blocklist.txt Generated/
../shared/copy-ubo.sh Generated/uBOLite
swift ../shared/Assets/make-icon.swift ios ../shared/Assets/logo.svg Generated/Assets.xcassets/AppIcon.appiconset/icon.png
echo '{ "info": { "author": "xcode", "version": 1 } }' > Generated/Assets.xcassets/Contents.json
cat > Generated/Assets.xcassets/AppIcon.appiconset/Contents.json <<'JSON'
{ "images": [ { "filename": "icon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024" } ],
  "info": { "author": "xcode", "version": 1 } }
JSON
xcodegen generate --quiet

case "${1:-sim}" in
sim)
    sim="${SIMULATOR:-iPhone 17}"
    xcodebuild -project Lumen.xcodeproj -scheme Lumen -configuration Debug -derivedDataPath build \
        -destination "platform=iOS Simulator,name=$sim" -quiet build
    xcrun simctl boot "$sim" 2>/dev/null || true
    open -b com.apple.iphonesimulator 2>/dev/null || true # the simulator window, when that app exists
    xcrun simctl install "$sim" build/Build/Products/Debug-iphonesimulator/Lumen.app
    if [ "${2:-}" = --selftest ]; then
        xcrun simctl launch --console-pty --terminate-running-process "$sim" "$bundle_id" --selftest
    else
        xcrun simctl launch --terminate-running-process "$sim" "$bundle_id"
    fi
    ;;
device)
    # Pick the device first: building for it lets Xcode register a new device with the free team and
    # put it in the provisioning profile (a generic iOS build left the iPad out and its install failed).
    devices=$(mktemp)
    xcrun devicectl list devices --json-output "$devices" >/dev/null
    device=$(python3 -I -c '
import json, sys
# A booted simulator is listed too (a new device may not report "physical" yet, so simulators are what
# is left out). A paired device that is not connected yet ("available") is fine: devicectl connects to
# it for the install. DEVICE narrows it down by name (case-insensitive).
want = sys.argv[2].lower()
for d in json.load(open(sys.argv[1]))["result"]["devices"]:
    name = d.get("deviceProperties", {}).get("name", "")
    udid = d.get("hardwareProperties", {}).get("udid", "")
    if d.get("hardwareProperties", {}).get("reality") != "simulated" \
            and d.get("connectionProperties", {}).get("pairingState") == "paired" \
            and (want in name.lower() or want == udid.lower()):
        print(d["hardwareProperties"]["udid"], d["identifier"]); break' "$devices" "${DEVICE:-}")
    rm -f "$devices"
    [ -n "$device" ] || { echo "No paired iPhone/iPad${DEVICE:+ named *$DEVICE*}: plug it in and unlock it." >&2; exit 1; }
    read -r udid identifier <<< "$device"
    xcodebuild -project Lumen.xcodeproj -scheme Lumen -configuration Release -derivedDataPath build \
        -destination "id=$udid" -allowProvisioningUpdates -allowProvisioningDeviceRegistration -quiet build
    xcrun devicectl device install app --device "$identifier" build/Build/Products/Release-iphoneos/Lumen.app
    [ "${2:-}" = --no-launch ] || xcrun devicectl device process launch --device "$identifier" "$bundle_id"
    ;;
*)
    echo "usage: ./build.sh sim [--selftest] | device [--no-launch]" >&2
    exit 2
    ;;
esac
