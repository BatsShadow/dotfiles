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
EXCLUDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-id) APP_ID="$2"; shift 2 ;;
    --app-name) APP_NAME="$2"; shift 2 ;;
    --workspace) WORKSPACE="$2"; shift 2 ;;
    --find-title) FIND_TITLE="$2"; shift 2 ;;
    --find-args) FIND_ARGS="$2"; shift 2 ;;
    --on-focus) ON_FOCUS="$2"; shift 2 ;;
    --url) URL="$2"; shift 2 ;;
    --exclude) EXCLUDE="$2"; shift 2 ;;
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

  # Check if already focused on the target window
  FOCUSED_APP=$(aerospace list-windows --focused --format '%{app-bundle-id}' 2>/dev/null)
  FOCUSED_TITLE=$(aerospace list-windows --focused --format '%{window-title}' 2>/dev/null)

  ALREADY_FOCUSED=false
  if [ "$FOCUSED_APP" = "$APP_ID" ]; then
    if [ -n "$FIND_TITLE" ]; then
      # Only count as focused if the title matches (e.g. focused on YouTube Arc, not Browser Arc)
      echo "$FOCUSED_TITLE" | grep -qi "$FIND_TITLE" && ALREADY_FOCUSED=true
    elif [ -n "$EXCLUDE" ]; then
      # For browser: focused on Arc but NOT a Gmail/YouTube window
      echo "$FOCUSED_TITLE" | grep -qiE "$EXCLUDE" || ALREADY_FOCUSED=true
    else
      ALREADY_FOCUSED=true
    fi
  fi

  if [ "$ALREADY_FOCUSED" = true ] && [ -n "$ON_FOCUS" ]; then
    echo "Already focused, running on-focus action..."
    eval "$ON_FOCUS"
    exit 0
  fi

  # Check if the target window is on the OTHER tiles workspace
  CURRENT_WS=$(aerospace list-workspaces --focused 2>/dev/null)
  if [ "$CURRENT_WS" = "Tiles" ]; then
    OTHER_WS="Tiles2"
  else
    OTHER_WS="Tiles"
  fi
  if [ -n "$FIND_TITLE" ]; then
    OTHER_WINDOW=$("$SCRIPT_DIR/find-window.sh" "$FIND_TITLE" "--workspace $OTHER_WS")
  else
    OTHER_WINDOW=$("$SCRIPT_DIR/find-window.sh" "$APP_NAME" "--workspace $OTHER_WS" "app-name" ${EXCLUDE:+--exclude "$EXCLUDE"})
  fi
  if [ -n "$OTHER_WINDOW" ]; then
    aerospace workspace "$OTHER_WS"
    aerospace focus --window-id "$(echo "$OTHER_WINDOW" | head -n 1)"
    exit 0
  fi

  # Switch to the window on current workspace
  if [ -n "$FIND_TITLE" ]; then
    "$SCRIPT_DIR/tile-mode/split-focus.aerospace.sh" "$FIND_TITLE"
  else
    # Build args array to avoid eval
    ARGS=("$APP_NAME")
    if [ -n "$FIND_ARGS" ]; then
      # Split FIND_ARGS into separate words
      read -ra EXTRA <<< "$FIND_ARGS"
      ARGS+=("${EXTRA[@]}")
    else
      ARGS+=(--all app-name)
    fi
    if [ -n "$EXCLUDE" ]; then
      ARGS+=(--exclude "$EXCLUDE")
    fi
    "$SCRIPT_DIR/tile-mode/split-focus.aerospace.sh" "${ARGS[@]}"
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

  # Switch to workspace and explicitly focus a window on it
  # (prevents Arc from focusing a window on another monitor/workspace)
  aerospace workspace "$TARGET_WS"
  TARGET_WINDOW=$(aerospace list-windows --workspace "$TARGET_WS" --format '%{window-id}' 2>/dev/null | head -n 1)
  if [ -n "$TARGET_WINDOW" ]; then
    aerospace focus --window-id "$TARGET_WINDOW"
  fi
  "$SCRIPT_DIR/workspace-mode/auto-config.aerospace.sh" W
fi
