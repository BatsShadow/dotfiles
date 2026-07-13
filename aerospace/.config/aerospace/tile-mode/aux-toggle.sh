#!/usr/bin/env bash
# alt-shift-a: the single-slot Aux stash (built-in monitor, workspace Tiles2).
# Replaces the old alt-shift-tab monitor-toggle. Stateful:
#
#   Aux EMPTY    -> pin the focused window to Aux. Focus FOLLOWS (the window you
#                   were on just moved). If the focused window is the Stage
#                   master, promote the Rail front to the Stage first so the
#                   Stage never empties.
#   Aux OCCUPIED -> return the Aux window to the Rail. Focus STAYS PUT on whatever
#                   you had focused. (This is what makes the two-tap swap work:
#                   press once to evict the old reference, press again to pin the
#                   window you are still focused on.)
#
# Single occupancy is enforced for free: an occupied Aux always evicts first, so
# a second window can never land there.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
trace_begin "aux-toggle.sh"

dual_monitor || exit 0    # nowhere to stash when undocked

FOCUSED="$(focused_window)"
read_lines AUX < <(secondary_windows)
AUX_WIN="${AUX[0]:-}"

# --- Aux occupied: evict it back to the Rail, keep focus where it is. ---
if [ -n "$AUX_WIN" ]; then
  aerospace move-node-to-workspace --window-id "$AUX_WIN" "$PRIMARY_WS"
  # A moved-in window lands at the root, so rebuild the canonical Stage+Rail.
  MASTER="$(get_master)"
  if [ -n "$MASTER" ] && window_exists "$MASTER" \
     && [ "$(window_workspace "$MASTER")" = "$PRIMARY_WS" ]; then
    "$TILE_DIR/relayout.sh" "$MASTER"
  else
    "$TILE_DIR/relayout.sh"
  fi
  # Restore focus to whatever was focused before (the swap idiom depends on this).
  aerospace workspace "$PRIMARY_WS"
  if [ -n "$FOCUSED" ] && window_exists "$FOCUSED"; then
    aerospace focus --window-id "$FOCUSED" 2>/dev/null
    [ "$(parent_layout "$FOCUSED")" = "v_accordion" ] && set_secondary "$FOCUSED"
  fi
  trace "aux evict $AUX_WIN -> rail (focus kept on ${FOCUSED:-none})"
  exit 0
fi

# --- Aux empty: pin the focused window there. Focus follows. ---
[ -z "$FOCUSED" ] && exit 0
OLD_MASTER="$(get_master)"

# If we are pinning the Stage master, promote the Rail front to the Stage first
# so the Stage stays populated after the master leaves.
if [ "$FOCUSED" = "$OLD_MASTER" ]; then
  PROMO="$(get_secondary)"
  if [ -z "$PROMO" ] || [ "$PROMO" = "$OLD_MASTER" ] \
     || [ "$(window_workspace "$PROMO")" != "$PRIMARY_WS" ]; then
    read_lines RW < <(tiles_windows)
    PROMO=""
    for w in "${RW[@]}"; do [ "$w" != "$OLD_MASTER" ] && PROMO="$w" && break; done
  fi
  [ -n "$PROMO" ] && "$TILE_DIR/promote.sh" "$PROMO"
fi

aerospace move-node-to-workspace --window-id "$FOCUSED" "$SECONDARY_WS"
aerospace workspace "$SECONDARY_WS"
aerospace focus --window-id "$FOCUSED" 2>/dev/null
trace "aux pin $FOCUSED (focus followed)"
