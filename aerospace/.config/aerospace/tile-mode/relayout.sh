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
  exit 0
fi

# --- Dual monitor: master (left) + weighted vertical stack (right). ---
# Secondary = supplied (old master) if valid & distinct, else first non-master.
if [ -z "$SECONDARY" ] || [ "$SECONDARY" = "$MASTER" ] || ! in_tiles "$SECONDARY"; then
  SECONDARY=""
  for w in "${WINS[@]}"; do
    [ "$w" != "$MASTER" ] && SECONDARY="$w" && break
  done
fi

# 1. flatten to root siblings, 2. stack everything vertically
aerospace flatten-workspace-tree
aerospace focus --window-id "$MASTER"
aerospace layout v_tiles

# 3. pop the master out to the left -> h_tiles[ master | v_tiles[rest] ]
aerospace focus --window-id "$MASTER"
aerospace move left

# 4. drive the secondary to the bottom of the right column
aerospace focus --window-id "$SECONDARY"
i=0
while [ "$i" -lt "$COUNT" ]; do
  aerospace move down 2>/dev/null || break
  i=$((i + 1))
done

# 5. enlarge the secondary at the bottom, then set the master ↔ column split
aerospace resize --window-id "$SECONDARY" height "$SECONDARY_HEIGHT" 2>/dev/null
aerospace resize --window-id "$MASTER" width "$(get_width)" 2>/dev/null

aerospace focus --window-id "$MASTER"
