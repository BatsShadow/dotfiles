#!/usr/bin/env bash
# Fold a stray root-level window on Tiles back into the rail.
#
# A window can end up as a stray top-level column (beside the master, NOT in the
# rail accordion) two ways, each caught by a different AeroSpace callback:
#
#   * on-window-detected  -> a brand-new window; the catch-all move-node-to-workspace
#     drops it at the tree root. Call with --settle so the move lands first.
#   * on-focus-changed     -> a window RETURNING from macOS-native fullscreen. It
#     already exists, so on-window-detected never re-fires; instead it regains
#     focus on exit, and AeroSpace re-tiles it at the root. This callback fires on
#     EVERY focus change, so the no-stray path must stay cheap (one list-windows,
#     no sleep) — that is the ~always case.
#
# When a stray is found: rebuild the canonical master+rail (the stray folds into
# the accordion) and leave the returned/new window focused at the rail front.
#
# A non-blocking lock makes this safe under on-focus-changed: the focus() and
# relayout calls this script itself makes fire more on-focus-changed events, whose
# handlers hit the held lock and exit immediately — no re-entrancy, no double
# relayout, no focus-event feedback loop.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

SETTLE=0
[ "${1:-}" = "--settle" ] && SETTLE=1

# Only meaningful in tile mode with a canonical master.
[ "$(cat "$AERO_DIR/.current-mode" 2>/dev/null)" = "tile" ] || exit 0

# Non-blocking lock (atomic mkdir). If an integration is already running, the
# focus/relayout events it triggers land here — just bow out.
LOCK="$TILE_DIR/.rail-integrate.lock"
mkdir "$LOCK" 2>/dev/null || exit 0
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

trace_begin "rail-integrate.sh ${1:-}"

[ "$SETTLE" = 1 ] && sleep 0.1   # let the catch-all's move-node-to-workspace settle

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
