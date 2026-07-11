#!/usr/bin/env bash
# Shared helpers + state for the rewritten tile mode.
# Sourced by relayout.sh, promote.sh, app.sh, monitor-toggle.sh, etc.

TILE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AERO_DIR="$(cd "$TILE_DIR/.." && pwd)"

# --- Workspaces ---
PRIMARY_WS="Tiles"     # primary tiling workspace (lands on the main / XDR monitor)
SECONDARY_WS="Tiles2"  # capacity-1 reference slot (pinned to the built-in monitor)

# --- State files (gitignored) ---
MASTER_FILE="$TILE_DIR/.tile-master"        # window-id of the current master
WIDTH_FILE="$TILE_DIR/.tile-master-width"   # master width in logical px (tunable)

# --- Tunables (starting geometry; alt-R/alt-S adjust the width live) ---
DEFAULT_MASTER_WIDTH=1900   # reasonable master width on the XDR; tune to taste
MIN_MASTER_WIDTH=500
WIDTH_STEP=80               # px per alt-R / alt-S press
SECONDARY_HEIGHT=900        # height of the big bottom secondary (dual-monitor)

# --- Read an array portably (macOS ships bash 3.2, no mapfile) ---
# usage: read_lines ARRAYNAME < <(command)
read_lines() {
  local __name="$1" __line
  eval "$__name=()"
  while IFS= read -r __line; do
    [ -n "$__line" ] && eval "$__name+=(\"\$__line\")"
  done
}

# --- Monitors ---
monitor_count() { aerospace list-monitors --count; }
xdr_id()     { aerospace list-monitors --format '%{monitor-id} %{monitor-name}' | grep -i 'XDR'      | awk '{print $1}' | head -n1; }
builtin_id() { aerospace list-monitors --format '%{monitor-id} %{monitor-name}' | grep -i 'built-in' | awk '{print $1}' | head -n1; }
dual_monitor() { [ "$(monitor_count)" -ge 2 ]; }

# --- Windows ---
# Tileable (non-floating) window-ids on the primary workspace, in tree order.
tiles_windows() {
  aerospace list-windows --workspace "$PRIMARY_WS" --json \
    --format '%{window-id} %{window-parent-container-layout}' 2>/dev/null \
  | jq -r '.[] | select(.["window-parent-container-layout"] != "floating") | .["window-id"]'
}
secondary_windows() {
  aerospace list-windows --workspace "$SECONDARY_WS" --format '%{window-id}' 2>/dev/null
}
focused_window() { aerospace list-windows --focused --format '%{window-id}' 2>/dev/null; }

window_exists() { aerospace list-windows --all --format '%{window-id}' 2>/dev/null | grep -qx "$1"; }
window_workspace() {
  aerospace list-windows --all --format '%{window-id}%{tab}%{workspace}' 2>/dev/null \
    | awk -F'\t' -v id="$1" '$1==id{print $2; exit}'
}

# --- Master state ---
get_master() { cat "$MASTER_FILE" 2>/dev/null; }
set_master() { echo "$1" > "$MASTER_FILE"; }

get_width() { local w; w="$(cat "$WIDTH_FILE" 2>/dev/null)"; echo "${w:-$DEFAULT_MASTER_WIDTH}"; }
set_width() { echo "$1" > "$WIDTH_FILE"; }
