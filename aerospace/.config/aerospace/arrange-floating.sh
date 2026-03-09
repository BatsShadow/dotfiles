#!/usr/bin/env bash
# Arrange floating windows in the left margin area (XDR) or centered (built-in).
# Called after tile mode arrangement to position floating windows nicely.
#
# On XDR: the left margin is ~710px. Floating windows get stacked vertically
# in that space with even spacing.
# On built-in: floating windows are left as-is (centered by default).
#
# Note: AeroSpace doesn't currently support setting floating window position/size
# via CLI. This script is a placeholder for when that capability is added,
# or can be extended with AppleScript/accessibility APIs to move windows.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CURRENT_MONITOR=$(aerospace list-monitors --focused --format '%{monitor-name}')

# Get floating window IDs
FLOATING=$(aerospace list-windows --workspace visible \
  --format '%{window-id} %{window-parent-container-layout}' 2>/dev/null | \
  grep 'floating$' | awk '{print $1}')

if [ -z "$FLOATING" ]; then
  exit 0
fi

echo "Floating windows to arrange: $FLOATING"

# TODO: When aerospace adds move-to-position support, arrange floating
# windows in the left margin. For now, just ensure they stay floating.
for win in $FLOATING; do
  aerospace layout --window-id "$win" floating 2>/dev/null
done
