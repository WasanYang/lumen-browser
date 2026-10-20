#!/bin/bash
# Builds the iPhone/iPad app. Needs Xcode (used through DEVELOPER_DIR, so xcode-select can stay on the
# Command Line Tools) and XcodeGen (brew install xcodegen).
#   ./build.sh sim              build, install and open on the iPhone simulator (SIMULATOR="iPad Pro 11-inch (M5)" for iPad)
#   ./build.sh sim --selftest   same, then run the self-test in the simulator and print PASS/FAIL
#   ./build.sh device           build, install and open on the connected iPhone or iPad
#                               (free Apple ID: the app stops opening after 7 days; run this again)
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
    xcodebuild -project Lumen.xcodeproj -scheme Lumen -configuration Release -derivedDataPath build \
        -destination "generic/platform=iOS" -allowProvisioningUpdates -quiet build
    devices=$(mktemp)
    xcrun devicectl list devices --json-output "$devices" >/dev/null
    device=$(python3 -I -c '
import json, sys
# A booted simulator is listed too. A paired device that is not connected yet ("available") is fine:
# devicectl connects to it for the install.
for d in json.load(open(sys.argv[1]))["result"]["devices"]:
    if d.get("hardwareProperties", {}).get("reality") == "physical" \
            and d.get("connectionProperties", {}).get("pairingState") == "paired":
        print(d["identifier"]); break' "$devices")
    rm -f "$devices"
    [ -n "$device" ] || { echo "No iPhone/iPad connected: plug it in and unlock it." >&2; exit 1; }
    xcrun devicectl device install app --device "$device" build/Build/Products/Release-iphoneos/Lumen.app
    xcrun devicectl device process launch --device "$device" "$bundle_id"
    ;;
*)
    echo "usage: ./build.sh sim [--selftest] | device" >&2
    exit 2
    ;;
esac
