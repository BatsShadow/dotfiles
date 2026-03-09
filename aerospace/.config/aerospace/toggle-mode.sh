#!/usr/bin/env bash
# Toggle between tile mode and workspace mode.
# Uses a flag file to track the current mode.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE_FILE="$SCRIPT_DIR/.current-mode"

# Default to tile mode if no flag file
CURRENT_MODE=$(cat "$MODE_FILE" 2>/dev/null || echo "tile")

if [ "$CURRENT_MODE" = "tile" ]; then
  echo "Switching to workspace mode..."
  # Restore windows to their correct workspaces first
  "$SCRIPT_DIR/restore-workspaces.sh"
  # Then swap in workspace-mode config
  "$SCRIPT_DIR/workspace-mode/auto-config.aerospace.sh" W
  echo "workspace" > "$MODE_FILE"
  osascript -e 'display notification "Workspace Mode" with title "AeroSpace"' &
else
  echo "Switching to tile mode..."
  # Swap in tile-mode config (this also runs split-focus to arrange)
  "$SCRIPT_DIR/tile-mode/auto-config.aerospace.sh"
  echo "tile" > "$MODE_FILE"
  osascript -e 'display notification "Tile Mode" with title "AeroSpace"' &
fi
