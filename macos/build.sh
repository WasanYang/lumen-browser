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

# App icon from the shared logo (see make-icon.swift).
swift make-icon.swift ../shared/Assets/logo.svg build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$app/Contents/Resources/AppIcon.icns"

# uBlock Origin Lite's YouTube scriptlets, from the copy the Windows build bundles (see AdBlock.uBOScripts).
ubol=../windows/Extensions/uBOLite
dest="$app/Contents/Resources/uBOLite"
mkdir -p "$dest"
cp "$ubol/manifest.json" "$ubol/LICENSE.txt" "$dest/"
for world in main isolated; do
    mkdir -p "$dest/rulesets/scripting/scriptlet/$world"
    for file in scriptlet-begin ublock-filters ublock-experimental scriptlet-end; do
        cp "$ubol/rulesets/scripting/scriptlet/$world/$file.js" "$dest/rulesets/scripting/scriptlet/$world/"
    done
done
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
