#!/usr/bin/env bash
# alt-shift-tab: move a window between the primary (Tiles) and the built-in
# secondary monitor (Tiles2), which holds at most one window.
#
#   Focused window on the XDR (master or secondary)
#     -> SWAP it with the single built-in window (they trade places).
#        If the built-in is empty, it's a one-way push and the XDR refills.
#   Focused window on the built-in
#     -> PROMOTE it to master (old master demotes to secondary). No swap.
#   Single monitor -> no-op.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

dual_monitor || exit 0    # nowhere to push when undocked

FOCUSED="$(focused_window)"
[ -z "$FOCUSED" ] && exit 0
FWS="$(window_workspace "$FOCUSED")"

# --- Focused on the built-in: reclaim it as master (rotate). ---
if [ "$FWS" = "$SECONDARY_WS" ]; then
  "$TILE_DIR/promote.sh" "$FOCUSED"
  exit 0
fi

# --- Focused on the XDR: swap with the built-in window. ---
read_lines SEC < <(secondary_windows)
INCOMING="${SEC[0]:-}"          # window currently on the built-in (may be empty)
OLD_MASTER="$(get_master)"

# Send the focused window out to the built-in.
aerospace move-node-to-workspace --window-id "$FOCUSED" "$SECONDARY_WS"

if [ -n "$INCOMING" ]; then
  # Bring the built-in window into the vacated slot.
  aerospace move-node-to-workspace --window-id "$INCOMING" "$PRIMARY_WS"
  if [ "$FOCUSED" = "$OLD_MASTER" ]; then
    "$TILE_DIR/promote.sh" "$INCOMING"        # incoming becomes the new master
  else
    "$TILE_DIR/relayout.sh" "$OLD_MASTER" "$INCOMING"  # incoming becomes secondary
  fi
else
  # One-way push. If we sent the master away, let relayout pick a new one.
  [ "$FOCUSED" = "$OLD_MASTER" ] && set_master ""
  "$TILE_DIR/relayout.sh"
fi

# Land back on the XDR working area (the current master), not the parked window.
aerospace workspace "$PRIMARY_WS"
M="$(get_master)"
[ -n "$M" ] && aerospace focus --window-id "$M" 2>/dev/null
