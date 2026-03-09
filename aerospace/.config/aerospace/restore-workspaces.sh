#!/usr/bin/env bash
# Restore all windows from tile mode back to their correct workspaces
# using the resolver rules. Floating windows are moved too but stay floating.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOLVER="$SCRIPT_DIR/resolve-workspace.sh"

# Get all windows with needed fields
WINDOWS=$(aerospace list-windows --all --json \
  --format '%{window-id} %{app-bundle-id} %{window-title} %{window-parent-container-layout} %{monitor-name}')

# Track which workspaces get windows so we can pick one to focus
declare -A WORKSPACE_COUNTS

echo "$WINDOWS" | jq -c '.[]' | while read -r win; do
  WINDOW_ID=$(echo "$win" | jq -r '.["window-id"]')
  APP_ID=$(echo "$win" | jq -r '.["app-bundle-id"]')
  TITLE=$(echo "$win" | jq -r '.["window-title"]')
  LAYOUT=$(echo "$win" | jq -r '.["window-parent-container-layout"]')
  MONITOR=$(echo "$win" | jq -r '.["monitor-name"]')

  # Skip windows on secondary (non-XDR, non-built-in) monitors
  # Actually, just process all windows — the resolver handles everything

  TARGET=$("$RESOLVER" "$APP_ID" "$TITLE")
  echo "Moving window $WINDOW_ID ($APP_ID: $TITLE) -> $TARGET"
  aerospace move-node-to-workspace --window-id "$WINDOW_ID" "$TARGET"

  # If it was floating, re-set it to floating after the move
  if [ "$LAYOUT" = "floating" ]; then
    aerospace layout --window-id "$WINDOW_ID" floating
  fi
done

# Focus the Terminal workspace as a sensible default after restore
aerospace workspace Terminal
