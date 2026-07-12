#!/usr/bin/env bash
# Enter tile mode: gather every window onto the primary tiling workspace, seed the
# master from the previously-focused window (mode-toggle continuity), and lay it
# out.
#
# Windows are gathered straight into a single flat vertical accordion: the master
# goes in first and the Tiles root is forced to v_accordion, then every other
# window is moved in on top of it. In an accordion each arrival simply overlaps the
# previous window full-screen, so gathering causes NO tiling reshuffle (unlike
# moving windows into a tiled layout, which re-splits on every arrival and shrinks
# whatever is already there). relayout then ejects the master leftward in one move
# and — seeing the tree is already a flat accordion — skips the flatten, so the
# whole entry never explodes windows into a grid. See FLICKER-PLAN.md S8.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
trace_begin "enter.sh $*"

# Continuity: whatever app you were focused on in workspace mode becomes master.
DESIRED_MASTER="$(focused_window)"

# Master in first; force the Tiles root to a single vertical accordion so every
# window that follows stacks into it instead of tiling beside it.
if [ -n "$DESIRED_MASTER" ]; then
  aerospace move-node-to-workspace --window-id "$DESIRED_MASTER" "$PRIMARY_WS" 2>/dev/null
  aerospace workspace "$PRIMARY_WS" 2>/dev/null
  aerospace focus --window-id "$DESIRED_MASTER" 2>/dev/null
  aerospace layout v_accordion 2>/dev/null
fi

# Stack every other window into that accordion (each overlaps full-screen -> no
# tiling churn). Floating windows come along but stay floating (relayout ignores
# them); the built-in reference slot starts empty.
while IFS=$'\t' read -r wid ws; do
  [ -z "$wid" ] && continue
  [ "$wid" = "$DESIRED_MASTER" ] && continue
  [ "$ws" = "$PRIMARY_WS" ] && continue          # already home -> don't re-append
  aerospace move-node-to-workspace --window-id "$wid" "$PRIMARY_WS" 2>/dev/null
done < <(aerospace list-windows --all --format '%{window-id}%{tab}%{workspace}')
trace "windows stacked into accordion on $PRIMARY_WS"

[ -n "$DESIRED_MASTER" ] && set_master "$DESIRED_MASTER"
aerospace workspace "$PRIMARY_WS"
"$TILE_DIR/relayout.sh" "$DESIRED_MASTER"
