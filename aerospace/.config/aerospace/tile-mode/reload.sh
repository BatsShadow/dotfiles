#!/usr/bin/env bash
# Re-render the tile-mode config from source (globals + gaps + modes) and
# reload-config. A bare `aerospace reload-config` reloads the GENERATED
# aerospace.toml and therefore ignores fresh edits to modes.toml / globals.toml;
# this regenerates that artifact first, so source edits actually take effect.
# Does NOT run enter.sh, so the window layout is left untouched.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

TEMP="$(mktemp -t aerospace-config)"
render_config > "$TEMP"
cp "$TEMP" "$AERO_DIR/aerospace.toml"
aerospace reload-config

# Reload may rebalance the split; re-assert the master width so it stays put.
M="$(get_master)"
if [ -n "$M" ] && window_exists "$M"; then
  aerospace resize --window-id "$M" width "$(get_width)" 2>/dev/null
fi

osascript -e 'display notification "Config reloaded" with title "AeroSpace"' &
