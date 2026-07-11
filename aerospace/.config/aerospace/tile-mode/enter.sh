#!/usr/bin/env bash
# Enter tile mode: gather every window onto the primary tiling workspace, seed
# the master from the previously-focused window (mode-toggle continuity), and
# lay everything out.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

# Continuity: whatever app you were focused on in workspace mode becomes master.
DESIRED_MASTER="$(focused_window)"

# Pull all windows onto Tiles. Floating windows come along but stay floating
# (relayout ignores them); the built-in reference slot starts empty.
read_lines ALL < <(aerospace list-windows --all --format '%{window-id}')
for w in "${ALL[@]}"; do
  aerospace move-node-to-workspace --window-id "$w" "$PRIMARY_WS" 2>/dev/null
done

[ -n "$DESIRED_MASTER" ] && set_master "$DESIRED_MASTER"
aerospace workspace "$PRIMARY_WS"
"$TILE_DIR/relayout.sh" "$DESIRED_MASTER"
