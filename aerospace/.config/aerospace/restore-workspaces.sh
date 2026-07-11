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

# Continuity: land on the tile-mode master's resolved workspace (fall back to
# Terminal). By now the restore loop has already moved it to that workspace.
MASTER=$(cat "$SCRIPT_DIR/tile-mode/.tile-master" 2>/dev/null)
TARGET=""
if [ -n "$MASTER" ]; then
  INFO=$(aerospace list-windows --all --json --format '%{window-id} %{app-bundle-id} %{window-title}' 2>/dev/null \
    | jq -r --arg id "$MASTER" '.[] | select((.["window-id"]|tostring) == $id) | "\(.["app-bundle-id"])\t\(.["window-title"])"')
  APP=$(printf '%s' "$INFO" | cut -f1)
  TITLE=$(printf '%s' "$INFO" | cut -f2-)
  [ -n "$APP" ] && TARGET=$("$RESOLVER" "$APP" "$TITLE")
fi

if [ -n "$TARGET" ]; then
  aerospace workspace "$TARGET"
  aerospace focus --window-id "$MASTER" 2>/dev/null
else
  aerospace workspace Terminal
fi
