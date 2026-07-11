#!/usr/bin/env bash
# Narrow / widen the XDR outer gaps (left + right together, ratio preserved).
# AeroSpace has no runtime gap command, so we persist the new LEFT gap, re-render
# the config with the substituted values, and reload-config. The master width is
# re-applied afterwards in case the reload rebalanced the split.
#   alt-W -> narrow (smaller gaps; master shifts left, accordion widens)
#   alt-F -> widen  (larger gaps;  master shifts right, accordion narrows)
#
# Usage: resize-gap.sh narrow|widen
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

L="$(get_gap_left)"
case "${1:-}" in
  narrow|-|w) L=$((L - GAP_STEP)) ;;
  widen|+|f)  L=$((L + GAP_STEP)) ;;
  *) exit 0 ;;
esac
[ "$L" -lt "$GAP_MIN" ] && L="$GAP_MIN"
[ "$L" -gt "$GAP_MAX" ] && L="$GAP_MAX"
set_gap_left "$L"

# Re-render the config with the new gap values and reload.
TEMP="$(mktemp -t aerospace-config)"
render_config > "$TEMP"
cp "$TEMP" "$AERO_DIR/aerospace.toml"
aerospace reload-config

# Reload may rebalance the split; re-assert the master width so it stays put.
M="$(get_master)"
if [ -n "$M" ] && window_exists "$M"; then
  aerospace resize --window-id "$M" width "$(get_width)" 2>/dev/null
fi
