#!/bin/bash
# Re-adds the robbie.cliamp bar widget after "omarchy refresh shell" wipes it
# from shell.json. Triggered by the cliamp-remote-bar.path systemd user unit
# on every shell.json write.
#
# A refresh is detected by the shell.json.bak.<epoch> backup that
# omarchy-refresh-config leaves next to shell.json (it only writes one when
# the refreshed content differs from what was there). Removing the widget on
# purpose never creates a backup, so this script stays out of the way.
set -u

CONFIG_DIR="$HOME/.config/omarchy"
CONFIG="$CONFIG_DIR/shell.json"
ID="robbie.cliamp"

widget_present() {
  python3 -c "import json,sys
d = json.load(open('$CONFIG'))
sys.exit(0 if any(w.get('id') == '$ID' for s in ('left', 'center', 'right')
                  for w in d.get('bar', {}).get('layout', {}).get(s, [])) else 1)" 2>/dev/null
}

# Let a refresh's multi-step rewrites (refresh-config, bar defaults) settle
# before asserting — the path unit is debounced, but this avoids racing the
# in-flight restart.
sleep 3

for _ in 1 2 3 4 5 6 7 8 9 10; do
  [[ -f $CONFIG ]] && break
  sleep 1
done
[[ -f $CONFIG ]] || exit 0

widget_present && exit 0

# No fresh backup means this write was not a refresh: leave the removal alone.
find "$CONFIG_DIR" -maxdepth 1 -name 'shell.json.bak.*' -mmin -5 -print -quit 2>/dev/null |
  grep -q . || exit 0

# Placement is the live shell's call, and it may still be restarting or
# holding the pre-refresh config in memory, so retry until it lands.
for _ in 1 2 3 4 5 6; do
  omarchy bar put "$ID" --section left >/dev/null 2>&1 || true
  widget_present && exit 0
  sleep 2
done

echo "ensure-bar: could not place $ID on the bar" >&2
exit 1
