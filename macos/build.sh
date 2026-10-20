#!/bin/bash
# Builds build/Lumen.app (release). Needs only the Command Line Tools: xcode-select --install
#   ./build.sh            build only
#   ./build.sh --install  build, then replace /Applications/Lumen.app (logins are kept: they live
#                         under the bundle ID in ~/Library, not inside the app)
set -euo pipefail
cd "$(dirname "$0")"

install=false
case "${1:-}" in
    "") ;;
    --install) install=true ;;
    *) echo "usage: ./build.sh [--install]" >&2; exit 2 ;;
esac

swift build -c release
bin="$(swift build -c release --show-bin-path)/Lumen"

app=build/Lumen.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/Lumen"
cp Info.plist "$app/Contents/Info.plist"
cp ../shared/blocklist.txt "$app/Contents/Resources/blocklist.txt"

# App icon from the shared logo.
swift ../shared/Assets/make-icon.swift mac ../shared/Assets/logo.svg build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$app/Contents/Resources/AppIcon.icns"

# uBlock Origin Lite's YouTube scriptlets, bundled as the starting copy (LumenCore's UBOLite).
../shared/copy-ubo.sh "$app/Contents/Resources/uBOLite"
# Ad-hoc signature: enough to run on this Mac. Sharing with other Macs needs a Developer ID.
codesign --force --sign - "$app"
echo "$app"

if $install; then
    target=/Applications/Lumen.app
    if pgrep -xf "$target/Contents/MacOS/Lumen" >/dev/null; then
        echo "Lumen is running from $target. Quit it (⌘Q), then run ./build.sh --install again." >&2
        exit 1
    fi
    rm -rf "$target"
    ditto "$app" "$target"
    touch "$target" # so Finder and the Dock pick up a changed icon
    echo "installed $target"
fi
