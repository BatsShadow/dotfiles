#!/usr/bin/env bash
# Idempotent relayout of the primary tiling workspace (Tiles).
#
# Target tree:  h_tiles[ master | v_stack[ …small stack…, big secondary ] ]
#   - dual-monitor : right column is v_tiles, secondary enlarged at the bottom
#   - single-monitor: right column is v_accordion so the secondary stays large
#
# Rebuilds from scratch every call, so it always converges regardless of the
# starting arrangement (avoids fragile incremental tree surgery).
#
# Usage: relayout.sh [master-window-id] [secondary-window-id]
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
trace_begin "relayout.sh $*"

MASTER="${1:-$(get_master)}"
SECONDARY="${2:-}"

read_lines WINS < <(tiles_windows)
COUNT=${#WINS[@]}

in_tiles() { local x; for x in "${WINS[@]}"; do [ "$x" = "$1" ] && return 0; done; return 1; }

# Validate master: must be a tileable window on Tiles; else fall back to first.
if [ -z "$MASTER" ] || ! in_tiles "$MASTER"; then
  MASTER="${WINS[0]:-}"
fi
[ -z "$MASTER" ] && exit 0    # nothing to lay out
set_master "$MASTER"

aerospace workspace "$PRIMARY_WS"

# Single tileable window: it is the master, full workspace.
if [ "$COUNT" -le 1 ]; then
  aerospace flatten-workspace-tree
  aerospace focus --window-id "$MASTER" 2>/dev/null
  set_secondary ""
  exit 0
fi

# --- Single monitor: one accordion stack (focused = full size, rest peek). ---
# On the small built-in screen a weighted master+column shrinks the secondary too
# much, so we use a single accordion where whichever window you focus is large.
if ! dual_monitor; then
  aerospace flatten-workspace-tree
  aerospace focus --window-id "$MASTER"
  aerospace layout h_accordion
  aerospace focus --window-id "$MASTER"
  set_secondary ""
  exit 0
fi

# --- Dual monitor: master (left) + accordion column (right). ---
# Secondary = supplied (old master) if valid & distinct, else first non-master.
# In the accordion, the "secondary" is simply whichever window is focused: it is
# drawn large while the other "extra" windows peek behind it (accordion-padding).
# The accordion can never occlude the secondary — extras are layered behind, not
# tiled beside it — so the big window stays fully visible regardless of count.
if [ -z "$SECONDARY" ] || [ "$SECONDARY" = "$MASTER" ] || ! in_tiles "$SECONDARY"; then
  SECONDARY=""
  for w in "${WINS[@]}"; do
    [ "$w" != "$MASTER" ] && SECONDARY="$w" && break
  done
fi

# Build the target tree: h_tiles[ master | v_accordion[ …extras… ] ] via the
# accordion-EJECT method (least-flicker; see FLICKER-PLAN.md S8):
#
# 1. collapse every window into a single flat vertical accordion (root
#    v_accordion). If the tree is ALREADY a flat accordion — e.g. enter.sh
#    gathered the windows straight into it — SKIP the flatten, so entry never
#    passes through the "explode into COUNT equal grid tiles" flicker storm.
# 2. eject the master leftward in ONE move. From a root v_accordion, `move left`
#    pops the master out to h_tiles[ master | v_accordion[ rest ] ], leaving the
#    others as a clean vertical accordion column — no force-h_tiles, no per-window
#    pop, no v_tiles->v_accordion conversion (verified on 0.21.2).
# In the accordion, position does not matter: the visible/front window is simply
# whichever is focused last, and that z-order survives focus moving to the master.
trace "0 start (COUNT=$COUNT MASTER=$MASTER SECONDARY=$SECONDARY)"
if all_in_accordion; then
  trace "1 already a flat accordion -> skip flatten"
else
  aerospace flatten-workspace-tree
  aerospace focus --window-id "$MASTER"
  aerospace layout v_accordion            # root -> single flat vertical accordion
  trace "1 flatten + root v_accordion"
fi
aerospace focus --window-id "$MASTER"
aerospace move left                        # eject master -> h_tiles[master | column]
trace "2 master ejected left"

# focus the SECONDARY *last* so it becomes the accordion's frontmost window. An
# unfocused accordion keeps drawing whichever of its windows was focused most
# recently on top of the rest (verified via CGWindowList z-order), and that
# survives moving focus out to the master below.
[ -n "$SECONDARY" ] && aerospace focus --window-id "$SECONDARY"
trace "3 secondary focused (front)"

# set the master ↔ column split width and land focus on the master. A short settle
# is required: the window server needs a beat to raise the secondary to the front
# after the rebuild, otherwise the master-focus lands first and an extra window
# stays frontmost (verified via CGWindowList z-order).
[ -n "$SECONDARY" ] && sleep 0.25
aerospace resize --window-id "$MASTER" width "$(get_width)" 2>/dev/null
aerospace focus --window-id "$MASTER"
set_secondary "$SECONDARY"
trace "4 resize master + focus master (final)"
