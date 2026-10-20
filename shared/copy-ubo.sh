#!/bin/bash
# Copies the uBlock Origin Lite files LumenCore needs (UBOLite.files) from the copy the Windows build
# bundles into <dest>, keeping uBO's own layout. Used by macos/build.sh and ios/build.sh.
set -euo pipefail
dest="$1"
ubol="$(cd "$(dirname "$0")/../windows/Extensions/uBOLite" && pwd)"
rm -rf "$dest"
mkdir -p "$dest"
cp "$ubol/manifest.json" "$ubol/LICENSE.txt" "$dest/"
for world in main isolated; do
    mkdir -p "$dest/rulesets/scripting/scriptlet/$world"
    for file in scriptlet-begin ublock-filters ublock-experimental scriptlet-end; do
        cp "$ubol/rulesets/scripting/scriptlet/$world/$file.js" "$dest/rulesets/scripting/scriptlet/$world/"
    done
done
