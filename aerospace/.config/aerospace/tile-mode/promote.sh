#!/usr/bin/env bash
# Promote a window to master. The old master rotates down into the big secondary
# slot (top/front of the accordion). Pressing two app keys back and forth toggles
# the two apps between master and secondary.
#
# Three paths, cheapest first (see FLICKER-PLAN.md):
#   S2     target is ALREADY the master        -> just focus it, no relayout  (F=0)
#   S3/S4  target is any window in the column   -> swap it with the master     (F=2)
#   full   otherwise                            -> relayout.sh rebuild
#
# If the target window is on the secondary monitor, it is pulled onto Tiles first.
#
# Usage: promote.sh [window-id]   (no arg -> stage the currently focused window,
#                                  which is how alt-shift-t "stage the focused
#                                  window" is wired.)
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
trace_begin "promote.sh $*"

NEW_MASTER="${1:-}"
[ -z "$NEW_MASTER" ] && NEW_MASTER="$(focused_window)"
[ -z "$NEW_MASTER" ] && exit 0

OLD_MASTER="$(get_master)"

# Pull the target onto the primary workspace if it lives anywhere else.
WS="$(window_workspace "$NEW_MASTER")"
if [ -n "$WS" ] && [ "$WS" != "$PRIMARY_WS" ]; then
  aerospace move-node-to-workspace --window-id "$NEW_MASTER" "$PRIMARY_WS"
  WS="$PRIMARY_WS"
fi

# --- S2: target is already the master -> focus it, done. No relayout. ---
if [ "$NEW_MASTER" = "$OLD_MASTER" ] && [ "$WS" = "$PRIMARY_WS" ]; then
  aerospace focus --window-id "$NEW_MASTER"
  trace "S2 no-op (target already master)"
  exit 0
fi

# Rotate: the previous master becomes the secondary (if still valid & distinct).
SECONDARY=""
if [ -n "$OLD_MASTER" ] && [ "$OLD_MASTER" != "$NEW_MASTER" ] && window_exists "$OLD_MASTER"; then
  SECONDARY="$OLD_MASTER"
fi

# --- S3/S4: target is any window in the accordion column -> swap it straight into
# the master slot. A column window's tree-left neighbour IS the master, so
# `focus target; swap left` exchanges exactly those two windows: target -> master,
# old master -> the accordion. Only 2 windows move, no flatten. Verified for both
# the front child (the secondary) and any peeking extra. Guard on the canonical
# shape and verify the swap actually crossed; if the layout has drifted, fall
# through to a full rebuild.
#
# The old master must end up as the column's FRONT (visible) window:
#   S3  target WAS the front child (the A<->B toggle) -> old master lands in the
#       vacated front slot automatically; a bare re-focus keeps it snappy.
#   S4  target was a peeking extra -> the resulting front is not deterministic, so
#       explicitly focus the old master, let the window server settle, then focus
#       the new master (the same focus-last + settle the rebuild uses).
if dual_monitor \
   && [ -n "$SECONDARY" ] \
   && [ "$(window_workspace "$OLD_MASTER")" = "$PRIMARY_WS" ] \
   && [ "$(parent_layout "$NEW_MASTER")" = "v_accordion" ] \
   && [ "$(parent_layout "$OLD_MASTER")" = "h_tiles" ]; then
  WAS_FRONT=0
  [ "$NEW_MASTER" = "$(get_secondary)" ] && WAS_FRONT=1
  aerospace focus --window-id "$NEW_MASTER"
  aerospace swap left 2>/dev/null
  if [ "$(parent_layout "$NEW_MASTER")" = "h_tiles" ]; then   # it crossed into master slot
    set_master "$NEW_MASTER"
    set_secondary "$OLD_MASTER"
    if [ "$WAS_FRONT" = 1 ]; then
      aerospace focus --window-id "$NEW_MASTER"
      trace "S3 swap fast-path (secondary <-> master)"
    else
      aerospace focus --window-id "$OLD_MASTER"   # raise old master to column front
      sleep 0.25                                  # settle before focusing out
      aerospace focus --window-id "$NEW_MASTER"
      trace "S4 swap fast-path (extra -> master, explicit front-set)"
    fi
    exit 0
  fi
  # swap did not cross (layout drifted) -> fall through to rebuild.
fi

# --- Full rebuild. ---
set_master "$NEW_MASTER"
"$TILE_DIR/relayout.sh" "$NEW_MASTER" "$SECONDARY"
aerospace focus --window-id "$NEW_MASTER" 2>/dev/null
