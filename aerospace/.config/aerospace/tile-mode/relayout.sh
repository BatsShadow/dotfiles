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

# Build the target tree: h_tiles[ master | v_accordion[ …extras…, secondary ] ].
#
# 1. flatten to root siblings.
# 2. force the ROOT horizontal (layout h_tiles). This is essential: if the root
#    is vertical, popping the master out only wraps it in an h_tiles *child* and
#    the root stays vertical -> master renders as a full-width bar ("wide main").
# 3. move the master left past the edge. Over-shooting ejects it to the root's
#    left and aerospace's orientation-alternation nests the remaining windows
#    into a column on the right. Result: h_tiles[ master | v_tiles[…] ].
trace "0 start (COUNT=$COUNT MASTER=$MASTER SECONDARY=$SECONDARY)"
aerospace flatten-workspace-tree
trace "1 flatten-workspace-tree"
aerospace focus --window-id "$MASTER"
aerospace layout h_tiles
trace "2 layout h_tiles (force root horizontal)"
aerospace focus --window-id "$MASTER"
i=0
while [ "$i" -lt "$COUNT" ]; do
  aerospace move left 2>/dev/null
  i=$((i + 1))
done
trace "3 master popped left x$COUNT"

# 4. raise the SECONDARY to the TOP of the column while it is still v_tiles.
#    `move` reorders a v_tiles column but is a NO-OP inside an accordion (verified
#    on 0.21.2 — neither `move` nor `swap` reorders accordion children), so the
#    ordering MUST happen before the accordion conversion. Being the first/top
#    child fixes the secondary's *position* at the top of the column; being drawn
#    *on top* (front) is handled separately by focusing it last in step 6. Guarded
#    move-up: raise one slot while a window still sits above it; stop the instant
#    nothing does, so it reaches the top without ejecting/collapsing the tree.
if [ -n "$SECONDARY" ]; then
  guard=0
  while [ "$guard" -lt "$COUNT" ]; do
    guard=$((guard + 1))
    aerospace focus --window-id "$SECONDARY"
    aerospace focus --boundaries workspace --boundaries-action stop up 2>/dev/null
    [ "$(focused_window)" = "$SECONDARY" ] && break   # nothing above -> at top
    aerospace focus --window-id "$SECONDARY"
    aerospace move up 2>/dev/null
  done
fi
trace "4 secondary raised to top of column"

# 5. convert the right column to a vertical accordion. Focus any window that is
#    in the column (not the master) and set its parent-container layout; the
#    master lives under the root h_tiles, so it is unaffected.
for w in "${WINS[@]}"; do
  if [ "$w" != "$MASTER" ]; then
    aerospace focus --window-id "$w"
    aerospace layout v_accordion
    break
  fi
done
trace "5 column -> v_accordion"

# 6. focus the SECONDARY *last* so it becomes the accordion's frontmost window. An
#    unfocused accordion keeps drawing whichever of its windows was focused most
#    recently on top of the rest — verified via CGWindowList z-order — and that
#    survives moving focus out to the master (step 7). Combined with step 4 (the
#    secondary is the first/top child) it is drawn large at the TOP of the column,
#    with the extras peeking below. This focus MUST come after the accordion
#    conversion in step 5, which itself focuses a column window.
[ -n "$SECONDARY" ] && aerospace focus --window-id "$SECONDARY"
trace "6 secondary focused (front)"

# 7. set the master ↔ column split width and land focus on the master. A short
#    settle delay is required: the window server needs a beat to raise the
#    secondary to the front of the column after the rapid rebuild above, otherwise
#    the master-focus lands first and an extra window stays frontmost (verified via
#    CGWindowList z-order — without the pause the secondary loses the front slot).
[ -n "$SECONDARY" ] && sleep 0.25
aerospace resize --window-id "$MASTER" width "$(get_width)" 2>/dev/null
aerospace focus --window-id "$MASTER"
set_secondary "$SECONDARY"
trace "7 resize master + focus master (final)"
