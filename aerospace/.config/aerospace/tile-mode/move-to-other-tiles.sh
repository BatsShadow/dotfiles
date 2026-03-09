#!/usr/bin/env bash
# Move the focused window between Tiles (primary) and Tiles2 (secondary monitor).
#
# Tiles → Tiles2: swap the window out of primary position first (to preserve
#   the 2-column layout), then move it to Tiles2
# Tiles2 → Tiles: move the window and swap it into the focused (left) position

CURRENT_WS=$(aerospace list-workspaces --focused 2>/dev/null)
WINDOW_ID=$(aerospace list-windows --focused --format '%{window-id}' 2>/dev/null)

if [ "$CURRENT_WS" = "Tiles" ]; then
  # Swap the window to the right (accordion) column before moving,
  # so the layout stays intact with a new window in the left position
  aerospace swap --window-id "$WINDOW_ID" right
  aerospace move-node-to-workspace --window-id "$WINDOW_ID" Tiles2
  aerospace workspace Tiles2
  aerospace focus --window-id "$WINDOW_ID"
elif [ "$CURRENT_WS" = "Tiles2" ]; then
  # Move from secondary to primary — swap into the focused (left) position
  aerospace move-node-to-workspace --window-id "$WINDOW_ID" Tiles
  aerospace workspace Tiles
  aerospace focus --window-id "$WINDOW_ID"
  aerospace swap --window-id "$WINDOW_ID" left
  aerospace focus --window-id "$WINDOW_ID"
fi
