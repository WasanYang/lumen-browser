#!/bin/bash
# Keeps Lumen opening on the owner's iPhone and iPad with a free Apple ID, where an app stops opening
# 7 days after it was signed: reinstalls it on each paired device 6 days after that device's last
# renewal (owner's choice, 21 Oct 2026; the spare day is for a failed try), over Wi-Fi or cable.
# launchd runs this every day at 07:30 (install-renew.sh); most days it has nothing to do.
# Quiet when it works; a Mac notification when a device could not be renewed. It tries again the next day.
# Log: ~/Library/Logs/Lumen/renew.log. Last renewal per device: ~/Library/Logs/Lumen/renew-state.
set -uo pipefail
cd "$(dirname "$0")"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

logs="$HOME/Library/Logs/Lumen"
mkdir -p "$logs"
state="$logs/renew-state"
touch "$state"
exec >>"$logs/renew.log" 2>&1
echo "== $(date '+%Y-%m-%d %H:%M:%S')"

renew_after=$((6 * 24 * 3600))
expires_after=$((7 * 24 * 3600))
now=$(date +%s)

notify() {
    osascript -e "display notification \"$2\" with title \"Lumen\" subtitle \"$1\"" || true
}

# Paired iPhones/iPads (not simulators), one "UDID<TAB>name" per line.
devices_json=$(mktemp)
xcrun devicectl list devices --json-output "$devices_json" >/dev/null
devices=$(python3 -I -c '
import json, sys
for d in json.load(open(sys.argv[1]))["result"]["devices"]:
    hw = d.get("hardwareProperties", {})
    if hw.get("reality") != "simulated" and d.get("connectionProperties", {}).get("pairingState") == "paired":
        print(hw.get("udid", "") + "\t" + d.get("deviceProperties", {}).get("name", "?"))' "$devices_json")
rm -f "$devices_json"
[ -n "$devices" ] || { echo "no paired device"; notify "ไม่พบ iPhone/iPad" "ต่ออายุ Lumen ไม่ได้ ดู log ที่ ~/Library/Logs/Lumen/renew.log"; exit 1; }

while IFS=$'\t' read -r udid name; do
    [ -n "$udid" ] || continue
    last=$(awk -v id="$udid" '$1 == id { print $2 }' "$state")
    if [ -n "$last" ] && [ $((now - last)) -lt $renew_after ]; then
        echo "$name: renewed $(( (now - last) / 3600 )) h ago, nothing to do"
        continue
    fi
    echo "$name: renewing"
    if DEVICE="$udid" ./build.sh device --no-launch </dev/null; then
        awk -v id="$udid" '$1 != id' "$state" > "$state.tmp" && echo "$udid $now" >> "$state.tmp" && mv "$state.tmp" "$state"
        echo "$name: renewed"
    else
        if [ -n "$last" ]; then
            left=$(( (last + expires_after - now) / 3600 ))
            when=$([ $left -gt 0 ] && echo "หมดอายุในอีกราว $left ชม." || echo "หมดอายุแล้ว")
        else
            when="ยังไม่เคยต่ออายุจากสคริปต์นี้"
        fi
        echo "$name: FAILED ($when)"
        notify "ต่ออายุบน $name ไม่สำเร็จ" "$when ให้เครื่องอยู่ Wi-Fi เดียวกับ Mac จะลองใหม่พรุ่งนี้ 7:30"
    fi
done <<< "$devices"
