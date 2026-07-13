#!/usr/bin/env bash
# Shorten / grow the Rail's accordion peek (AeroSpace accordion-padding). A bigger
# peek shows more of the other Rail windows (they get "taller"), at the cost of a
# slightly shorter front window. AeroSpace has no runtime command for this, so we
# persist the new value, re-render the config, and reload-config (same mechanism
# as resize-gap.sh). The master width is re-asserted afterwards in case the reload
# rebalanced the split.
#   alt-X -> shorter (smaller peek)
#   alt-C -> taller  (bigger peek)
#
# Usage: resize-accordion.sh shorter|taller
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

P="$(get_accordion_padding)"
case "${1:-}" in
  shorter|shrink|-|x) P=$((P - ACCORDION_STEP)) ;;
  taller|grow|+|c)    P=$((P + ACCORDION_STEP)) ;;
  *) exit 0 ;;
esac
[ "$P" -lt "$ACCORDION_MIN" ] && P="$ACCORDION_MIN"
[ "$P" -gt "$ACCORDION_MAX" ] && P="$ACCORDION_MAX"
set_accordion_padding "$P"

# Re-render the config with the new padding and reload.
TEMP="$(mktemp -t aerospace-config)"
render_config > "$TEMP"
cp "$TEMP" "$AERO_DIR/aerospace.toml"
aerospace reload-config

# Reload may rebalance the split; re-assert the master width so it stays put.
M="$(get_master)"
if [ -n "$M" ] && window_exists "$M"; then
  aerospace resize --window-id "$M" width "$(get_width)" 2>/dev/null
fi
