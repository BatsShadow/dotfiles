#!/usr/bin/env bash
# Unified app shortcut dispatcher for both tile and workspace modes.
#
# Workspace mode logic:
#   1. Count windows on the target workspace
#   2. If already on the target workspace → run --on-focus action (if provided)
#   3. If no windows on the target workspace → launch app / open URL, then switch
#   4. Otherwise → switch to workspace and auto-config gaps
#
# Tile mode logic:
#   1. If already focused on target → run --on-focus action
#   2. If app has windows → split-focus to it
#   3. If app not running → launch it
#
# Options:
#   --app-id <id>         Bundle ID to match (required)
#   --app-name <name>     App name for launching/finding (required)
#   --workspace <name>    Workspace name (workspace mode)
#   --find-title <title>  Find window by title substring (tile mode)
#   --find-args <args>    Extra args for find-window.sh (tile mode)
#   --on-focus <cmd>      Command to run if already on target workspace/window
#   --url <url>           URL to open in new Arc window if no matching window exists

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE=$(cat "$SCRIPT_DIR/.current-mode" 2>/dev/null || echo "tile")

# Parse arguments
APP_ID=""
APP_NAME=""
WORKSPACE=""
FIND_TITLE=""
FIND_ARGS=""
ON_FOCUS=""
URL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-id) APP_ID="$2"; shift 2 ;;
    --app-name) APP_NAME="$2"; shift 2 ;;
    --workspace) WORKSPACE="$2"; shift 2 ;;
    --find-title) FIND_TITLE="$2"; shift 2 ;;
    --find-args) FIND_ARGS="$2"; shift 2 ;;
    --on-focus) ON_FOCUS="$2"; shift 2 ;;
    --url) URL="$2"; shift 2 ;;
    *) shift ;;
  esac
done

if [ "$MODE" = "tile" ]; then
  # --- TILE MODE ---

  # Check if the app has any windows
  APP_WINDOW_COUNT=$(aerospace list-windows --all --format '%{app-bundle-id}' 2>/dev/null | grep -c "^${APP_ID}$")

  if [ "${APP_WINDOW_COUNT:-0}" -eq 0 ]; then
    echo "App $APP_NAME not running, launching..."
    if [ -n "$URL" ]; then
      "$SCRIPT_DIR/open-arc-url.sh" "$URL"
    else
      open -b "$APP_ID"
    fi
    exit 0
  fi

  # Check if already focused on this app
  FOCUSED_APP=$(aerospace list-windows --focused --format '%{app-bundle-id}' 2>/dev/null)

  if [ "$FOCUSED_APP" = "$APP_ID" ] && [ -n "$ON_FOCUS" ]; then
    echo "Already focused, running on-focus action..."
    eval "$ON_FOCUS"
    exit 0
  fi

  # Switch to the window
  if [ -n "$FIND_TITLE" ]; then
    "$SCRIPT_DIR/tile-mode/split-focus.aerospace.sh" "$FIND_TITLE"
  elif [ -n "$FIND_ARGS" ]; then
    eval "$SCRIPT_DIR/tile-mode/split-focus.aerospace.sh" "$APP_NAME" $FIND_ARGS
  else
    "$SCRIPT_DIR/tile-mode/split-focus.aerospace.sh" "$APP_NAME" --all app-name
  fi

else
  # --- WORKSPACE MODE ---

  TARGET_WS="${WORKSPACE}"
  if [ -z "$TARGET_WS" ]; then
    TARGET_WS=$("$SCRIPT_DIR/resolve-workspace.sh" "$APP_ID" "$FIND_TITLE")
  fi

  CURRENT_WS=$(aerospace list-workspaces --focused 2>/dev/null)

  # Check if the target app is running at all
  APP_EXISTS=$(aerospace list-windows --all --format '%{app-bundle-id}' 2>/dev/null \
    | grep -c "^${APP_ID}$")

  # Already on this workspace → run secondary action
  if [ "$CURRENT_WS" = "$TARGET_WS" ]; then
    if [ -n "$ON_FOCUS" ]; then
      echo "Already on $TARGET_WS, running on-focus action..."
      eval "$ON_FOCUS"
    fi
    exit 0
  fi

  # Target app/window doesn't exist → launch it
  if [ "${APP_EXISTS:-0}" -eq 0 ]; then
    echo "Target app/window not found, launching..."
    if [ -n "$URL" ]; then
      "$SCRIPT_DIR/open-arc-url.sh" "$URL"
    else
      open -b "$APP_ID"
    fi
    # Brief pause for the window to appear so auto-config counts it
    sleep 0.5
  fi

  # Switch to workspace and auto-config gaps
  aerospace workspace "$TARGET_WS"
  "$SCRIPT_DIR/workspace-mode/auto-config.aerospace.sh" W
fi
