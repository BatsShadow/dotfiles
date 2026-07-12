#!/usr/bin/env bash
# Promote a window to master. The old master rotates down into the big secondary
# slot (top/front of the accordion). Pressing two app keys back and forth toggles
# the two apps between master and secondary.
#
# Three paths, cheapest first (see FLICKER-PLAN.md):
#   S2  target is ALREADY the master        -> just focus it, no relayout   (F=0)
#   S3  target is the current secondary      -> swap it with the master      (F=2)
#   full  otherwise                          -> relayout.sh rebuild
#
# If the target window is on the secondary monitor, it is pulled onto Tiles first.
#
# Usage: promote.sh <window-id>
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
trace_begin "promote.sh $*"

NEW_MASTER="${1:-}"
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

# --- S3: target is the current secondary (accordion's top/front child) -> swap it
# straight into the master slot. The secondary's left neighbour IS the master, so
# `focus target; swap left` exchanges exactly those two windows: target -> master,
# old master -> top/front of the accordion. Only 2 windows move, no flatten, no
# settle. Guard on the canonical shape, and verify the swap actually crossed into
# the master slot; if the layout has drifted, fall through to a full rebuild.
if dual_monitor \
   && [ -n "$SECONDARY" ] \
   && [ "$NEW_MASTER" = "$(get_secondary)" ] \
   && [ "$(window_workspace "$OLD_MASTER")" = "$PRIMARY_WS" ] \
   && [ "$(parent_layout "$NEW_MASTER")" = "v_accordion" ] \
   && [ "$(parent_layout "$OLD_MASTER")" = "h_tiles" ]; then
  aerospace focus --window-id "$NEW_MASTER"
  aerospace swap left 2>/dev/null
  if [ "$(parent_layout "$NEW_MASTER")" = "h_tiles" ]; then   # it crossed into master slot
    set_master "$NEW_MASTER"
    set_secondary "$OLD_MASTER"
    aerospace focus --window-id "$NEW_MASTER"
    trace "S3 swap fast-path (secondary <-> master)"
    exit 0
  fi
  # swap did not cross (layout drifted) -> fall through to rebuild.
fi

# --- Full rebuild. ---
set_master "$NEW_MASTER"
"$TILE_DIR/relayout.sh" "$NEW_MASTER" "$SECONDARY"
aerospace focus --window-id "$NEW_MASTER" 2>/dev/null
