#!/usr/bin/env bash
# Fold a stray root-level window on Tiles back into the rail.
#
# Runs from the tile-mode on-window-detected catch-all, so it fires when a window
# is (re)detected: a brand-new window, OR a window returning from macOS-native
# fullscreen. Either way the catch-all's move-node-to-workspace drops it at the
# TREE ROOT (a third column beside master + rail-accordion) instead of in the
# rail. This detects that stray and rebuilds the canonical master+rail so the
# window rejoins the rail; the returned/new window is left focused at the rail
# front. If the layout is already canonical (no stray), it is a cheap no-op.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
trace_begin "rail-integrate.sh"

# Only meaningful in tile mode with a canonical master.
[ "$(cat "$AERO_DIR/.current-mode" 2>/dev/null)" = "tile" ] || exit 0

sleep 0.1   # let the catch-all's move-node-to-workspace settle first

MASTER="$(get_master)"

# A stray is a Tiles window parented directly by the root h_tiles (like the
# master) but that ISN'T the master — i.e. an extra top-level column. Rail
# windows live under the v_accordion, so they never match.
STRAY=""
while IFS=$'\t' read -r wid layout; do
  [ "$wid" = "$MASTER" ] && continue
  if [ "$layout" = "h_tiles" ]; then STRAY="$wid"; break; fi
done < <(aerospace list-windows --workspace "$PRIMARY_WS" \
           --format '%{window-id}%{tab}%{window-parent-container-layout}' 2>/dev/null)

if [ -z "$STRAY" ]; then
  trace "no stray at root; layout already canonical"
  exit 0
fi

# Rebuild canonical (the stray gets folded into the rail accordion), then focus
# the stray so the just-appeared / just-restored window stays in view.
"$TILE_DIR/relayout.sh"
aerospace focus --window-id "$STRAY" 2>/dev/null
[ "$(parent_layout "$STRAY")" = "v_accordion" ] && set_secondary "$STRAY"
trace "reintegrated stray $STRAY into rail"
