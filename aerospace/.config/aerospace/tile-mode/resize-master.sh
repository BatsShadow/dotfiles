#!/usr/bin/env bash
# Adjust the master ↔ right-column split. The width persists (state file) so it
# survives relayouts (app switches).
#   alt-R -> shrink master (split moves left)
#   alt-S -> grow  master (split moves right)
#
# Usage: resize-master.sh shrink|grow
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

W="$(get_width)"
case "${1:-}" in
  shrink|-|r) W=$((W - WIDTH_STEP)) ;;
  grow|+|s)   W=$((W + WIDTH_STEP)) ;;
esac
[ "$W" -lt "$MIN_MASTER_WIDTH" ] && W="$MIN_MASTER_WIDTH"
set_width "$W"

M="$(get_master)"
if [ -n "$M" ] && window_exists "$M"; then
  aerospace resize --window-id "$M" width "$W" 2>/dev/null
fi
