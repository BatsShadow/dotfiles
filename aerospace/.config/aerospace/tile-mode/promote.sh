#!/usr/bin/env bash
# Promote a window to master. The old master rotates down into the big secondary
# slot; the old secondary rotates up into the small stack. Pressing two app keys
# back and forth therefore toggles the two apps between master and secondary.
#
# If the target window is on the secondary monitor, it is pulled onto Tiles first.
#
# Usage: promote.sh <window-id>
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

NEW_MASTER="${1:-}"
[ -z "$NEW_MASTER" ] && exit 0

OLD_MASTER="$(get_master)"

# Pull the target onto the primary workspace if it lives anywhere else.
WS="$(window_workspace "$NEW_MASTER")"
if [ -n "$WS" ] && [ "$WS" != "$PRIMARY_WS" ]; then
  aerospace move-node-to-workspace --window-id "$NEW_MASTER" "$PRIMARY_WS"
fi

# Rotate: the previous master becomes the secondary (if still valid & distinct).
SECONDARY=""
if [ -n "$OLD_MASTER" ] && [ "$OLD_MASTER" != "$NEW_MASTER" ] && window_exists "$OLD_MASTER"; then
  SECONDARY="$OLD_MASTER"
fi

set_master "$NEW_MASTER"
"$TILE_DIR/relayout.sh" "$NEW_MASTER" "$SECONDARY"
aerospace focus --window-id "$NEW_MASTER" 2>/dev/null
