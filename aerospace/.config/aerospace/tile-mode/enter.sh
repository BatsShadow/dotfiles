#!/usr/bin/env bash
# Enter tile mode: gather every window onto the primary tiling workspace, seed
# the master from the previously-focused window (mode-toggle continuity), and
# lay everything out.
#
# Only windows NOT already on Tiles are moved. Re-issuing move-node-to-workspace
# for a window that is already there re-appends it in the tree and causes needless
# re-tiling churn. Normalizing the arrangement is left to the single relayout
# rebuild, which converges from any starting tree; an incremental append here
# would be fragile for a once-per-session action, so we keep the from-scratch
# rebuild rather than trying to place each window by hand.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
trace_begin "enter.sh $*"

# Continuity: whatever app you were focused on in workspace mode becomes master.
DESIRED_MASTER="$(focused_window)"

# Pull every window that is not already on Tiles onto Tiles. Floating windows come
# along but stay floating (relayout ignores them); the built-in reference slot
# starts empty.
while IFS=$'\t' read -r wid ws; do
  [ -z "$wid" ] && continue
  [ "$ws" = "$PRIMARY_WS" ] && continue          # already home -> don't re-append
  aerospace move-node-to-workspace --window-id "$wid" "$PRIMARY_WS" 2>/dev/null
done < <(aerospace list-windows --all --format '%{window-id}%{tab}%{workspace}')
trace "windows gathered onto $PRIMARY_WS"

[ -n "$DESIRED_MASTER" ] && set_master "$DESIRED_MASTER"
aerospace workspace "$PRIMARY_WS"
"$TILE_DIR/relayout.sh" "$DESIRED_MASTER"
