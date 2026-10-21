#!/bin/bash
# Makes launchd run renew.sh every day at 07:30 (if the Mac is asleep then, as soon as it wakes).
#   ./install-renew.sh             install or update the schedule
#   ./install-renew.sh --remove    stop it
# The schedule file points at this clone, so it lives only in ~/Library/LaunchAgents, not in git.
set -euo pipefail
label=io.github.wasanyang.lumen.renew
plist="$HOME/Library/LaunchAgents/$label.plist"
script="$(cd "$(dirname "$0")" && pwd)/renew.sh"

launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
if [ "${1:-}" = --remove ]; then
    rm -f "$plist"
    echo "removed $label"
    exit 0
fi

mkdir -p "$HOME/Library/LaunchAgents"
cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$label</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$script</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key>
        <integer>7</integer>
        <key>Minute</key>
        <integer>30</integer>
    </dict>
</dict>
</plist>
PLIST
launchctl bootstrap "gui/$(id -u)" "$plist"
echo "installed $label: daily at 07:30 → $script"
