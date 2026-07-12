#!/usr/bin/env bash
# alt-shift-tab: move the focused window between the primary tiling area (Tiles)
# and the built-in secondary monitor (Tiles2, a capacity-1 reference slot).
# Focus always FOLLOWS the window to its new screen.
#
#   Focused on the built-in
#     -> reclaim it as master on the XDR (promote). Focus follows to the XDR.
#   Focused on the XDR:
#     - if it is the MASTER, first PROMOTE THE SECONDARY (cheap swap) so the XDR
#       layout stays canonical; the window you are sending is then just the
#       accordion's front, and moving it out leaves a clean master + column. Then
#       send the old master to the built-in.
#     - if it is a column window, just send it out (the master is untouched).
#     If the built-in already holds a window, that window swaps back onto the XDR
#     (which needs a rebuild, since a moved-in window lands at the root).
#     Focus follows the sent window to the built-in.
#   Single monitor -> no-op.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
trace_begin "monitor-toggle.sh"

dual_monitor || exit 0    # nowhere to push when undocked

FOCUSED="$(focused_window)"
[ -z "$FOCUSED" ] && exit 0
FWS="$(window_workspace "$FOCUSED")"

# --- Focused on the built-in: reclaim it as master (focus follows to the XDR). ---
if [ "$FWS" = "$SECONDARY_WS" ]; then
  "$TILE_DIR/promote.sh" "$FOCUSED"
  trace "reclaimed $FOCUSED from built-in -> master"
  exit 0
fi

# --- Focused on the XDR: send FOCUSED out to the built-in. ---
read_lines SEC < <(secondary_windows)
INCOMING="${SEC[0]:-}"           # window currently parked on the built-in (may be empty)
OLD_MASTER="$(get_master)"

# First non-master tileable window on the XDR (skips floating), for picking a
# secondary/front. Prints nothing if the master is the only window.
xdr_first_non_master() {
  local w; read_lines __XW < <(tiles_windows)
  for w in "${__XW[@]}"; do [ "$w" != "$1" ] && echo "$w" && return; done
}

# If we're sending the MASTER, promote the secondary FIRST so the XDR layout stays
# canonical throughout; the window we send is then just the accordion's front, and
# moving it out leaves a clean master + column behind (no rebuild needed).
if [ "$FOCUSED" = "$OLD_MASTER" ]; then
  PROMO="$(get_secondary)"
  if [ -z "$PROMO" ] || [ "$PROMO" = "$OLD_MASTER" ] || [ "$(window_workspace "$PROMO")" != "$PRIMARY_WS" ]; then
    PROMO="$(xdr_first_non_master "$OLD_MASTER")"
  fi
  if [ -n "$PROMO" ]; then
    "$TILE_DIR/promote.sh" "$PROMO"       # swap: PROMO -> master, OLD_MASTER -> accordion front
    trace "promoted secondary $PROMO before sending old master"
  fi
fi

# Send the (now non-master) focused window out to the built-in.
aerospace move-node-to-workspace --window-id "$FOCUSED" "$SECONDARY_WS"

NEW_MASTER="$(get_master)"
if [ -n "$INCOMING" ] || [ -z "$NEW_MASTER" ] || [ "$(window_workspace "$NEW_MASTER")" != "$PRIMARY_WS" ]; then
  # Rebuild path: the built-in was occupied (swap its window back onto the XDR), or
  # the master is no longer valid on the XDR. Lay the XDR out cleanly from scratch.
  [ -n "$INCOMING" ] && aerospace move-node-to-workspace --window-id "$INCOMING" "$PRIMARY_WS"
  if [ -n "$NEW_MASTER" ] && [ "$(window_workspace "$NEW_MASTER")" = "$PRIMARY_WS" ]; then
    "$TILE_DIR/relayout.sh" "$NEW_MASTER"
  else
    set_master ""
    "$TILE_DIR/relayout.sh"
  fi
  trace "rebuilt XDR (incoming=${INCOMING:-none})"
else
  # Cheap path: the master + column are already intact; just re-designate a valid
  # front/secondary on the XDR (the window we sent out may have been it).
  NEW_SECONDARY="$(get_secondary)"
  if [ -z "$NEW_SECONDARY" ] || [ "$NEW_SECONDARY" = "$FOCUSED" ] \
     || [ "$NEW_SECONDARY" = "$NEW_MASTER" ] \
     || [ "$(window_workspace "$NEW_SECONDARY")" != "$PRIMARY_WS" ]; then
    NEW_SECONDARY="$(xdr_first_non_master "$NEW_MASTER")"
  fi
  if [ -n "$NEW_SECONDARY" ]; then
    aerospace focus --window-id "$NEW_SECONDARY"   # make it the accordion's front
    set_secondary "$NEW_SECONDARY"
  else
    set_secondary ""
  fi
  trace "cheap send; master=$NEW_MASTER front=${NEW_SECONDARY:-none}"
fi

# Focus follows the window to the built-in.
aerospace workspace "$SECONDARY_WS"
aerospace focus --window-id "$FOCUSED" 2>/dev/null
trace "focus followed $FOCUSED to built-in"
