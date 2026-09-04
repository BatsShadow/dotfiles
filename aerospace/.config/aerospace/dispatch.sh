#!/usr/bin/env bash
# Unified app shortcut dispatcher for both tile and workspace modes.
#
# Workspace mode logic:
#   1. Count windows on the target workspace
#   2. If already on the target workspace → run --on-focus action (if provided)
#   3. If no windows on the target workspace → launch app / open URL, then switch
#      (unless --no-launch: switch to the empty workspace without launching, or
#      the app already has a window on some other workspace: switch and say so)
#   4. Otherwise → switch to workspace and auto-config gaps
#
# Tile mode logic:
#   1. If already focused on target → run --on-focus action
#   2. If app has windows → split-focus to it
#   3. If app not running → launch it (unless --no-launch: do nothing)
#
# Options:
#   --app-id <id>         Bundle ID to match (required)
#   --app-name <name>     App name for launching/finding (required)
#   --workspace <name>    Workspace name (workspace mode)
#   --find-title <title>  Find window by title substring (tile mode)
#   --find-args <args>    Extra args for find-window.sh (tile mode)
#   --on-focus <cmd>      Command to run if already on target workspace/window
#   --url <url>           URL to open in new Arc window if no matching window exists
#   --no-launch           Never start the app. For apps that should only ever be
#                         opened by something else (Zoom, from a meeting link):
#                         the key navigates to them but cannot summon them.

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
NO_LAUNCH=0

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
    --no-launch) NO_LAUNCH=1; shift ;;
    *) shift ;;
  esac
done

if [ "$MODE" = "tile" ]; then
  # --- TILE MODE ---

  # Check if the app has any windows
  APP_WINDOW_COUNT=$(aerospace list-windows --all --format '%{app-bundle-id}' 2>/dev/null | grep -c "^${APP_ID}$")

  if [ "${APP_WINDOW_COUNT:-0}" -eq 0 ]; then
    if [ "$NO_LAUNCH" -eq 1 ]; then
      echo "App $APP_NAME not running and --no-launch set, nothing to focus."
      exit 0
    fi
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

  # Check if the target workspace has any windows
  WS_WINDOW_COUNT=$(aerospace list-windows --workspace "$TARGET_WS" --format '%{window-id}' 2>/dev/null | grep -c .)

  # Already on this workspace → run secondary action
  if [ "$CURRENT_WS" = "$TARGET_WS" ]; then
    if [ -n "$ON_FOCUS" ]; then
      echo "Already on $TARGET_WS, running on-focus action..."
      eval "$ON_FOCUS"
    fi
    exit 0
  fi

  # Target workspace is empty → launch the app. Under --no-launch we still make
  # the trip to the (empty) workspace; only the launch is skipped.
  if [ "${WS_WINDOW_COUNT:-0}" -eq 0 ] && [ "$NO_LAUNCH" -eq 0 ]; then
    # A window moved by hand to another workspace leaves this one empty, and
    # `open -b` on an app that is already running cannot conjure a second
    # window: it just activates the one that moved, dragging the screen to that
    # workspace for an instant before the switch below pulls it back. The window
    # looks like it flashed and vanished, with no hint of where it went. So say
    # where it went and leave it where the user put it. Opening a URL is the
    # exception, it really does make a new window, so it still runs.
    STRAY_WS=$(aerospace list-windows --all --format '%{app-bundle-id}|%{workspace}' 2>/dev/null |
      awk -F'|' -v id="$APP_ID" '
        $1 == id && !seen[$2]++ { ws[++n] = $2 }
        END {
          for (i = 1; i <= n; i++) {
            list = list (i == 1 ? "" : i == n ? " and " : ", ") ws[i]
          }
          print list
        }')

    if [ -z "$URL" ] && [ -n "$STRAY_WS" ]; then
      echo "$APP_NAME has no window on $TARGET_WS; it is on $STRAY_WS."
      SPACE_WORD="space"
      case "$STRAY_WS" in *" and "*) SPACE_WORD="spaces" ;; esac
      MSG="$APP_NAME is on the $STRAY_WS $SPACE_WORD"
      osascript -e "display notification \"${MSG//\"/\\\"}\" with title \"AeroSpace\"" &
    else
      echo "Target app/window not found, launching..."
      if [ -n "$URL" ]; then
        "$SCRIPT_DIR/open-arc-url.sh" "$URL"
      else
        open -b "$APP_ID"
      fi
      # Brief pause for the window to appear so auto-config counts it
      sleep 0.5
    fi
  fi

  # Cross-monitor displacement protection: when switching to a workspace
  # on another monitor, Arc activation can raise its last-focused window
  # (e.g. Gmail) on the original monitor. Save/restore only when the
  # target workspace is on a different monitor than we're currently on.
  FOCUSED_MONITOR=$(aerospace list-monitors --focused --format '%{monitor-id}' 2>/dev/null)
  XDR_ID=$(aerospace list-monitors | grep XDR | awk '{print $1}')
  SAVED_XDR_WS=""
  CROSS_MONITOR=false

  # Determine if this is a cross-monitor switch
  if [ -n "$XDR_ID" ]; then
    TARGET_MONITOR=$(aerospace list-windows --workspace "$TARGET_WS" --format '%{monitor-id}' 2>/dev/null | head -n 1)
    if [ -n "$TARGET_MONITOR" ] && [ "$TARGET_MONITOR" != "$FOCUSED_MONITOR" ]; then
      CROSS_MONITOR=true
      SAVED_XDR_WS=$(aerospace list-workspaces --visible --monitor "$XDR_ID" 2>/dev/null)
    fi
  fi

  # Check if target workspace is already visible on a monitor
  TARGET_WAS_VISIBLE=$(aerospace list-workspaces --visible --all 2>/dev/null | grep -c "^${TARGET_WS}$")

  aerospace workspace "$TARGET_WS"

  # Only explicitly focus a window when the workspace wasn't already visible.
  # Needed to prevent Arc from focusing the wrong window when bringing a
  # workspace from invisible to visible.
  if [ "${TARGET_WAS_VISIBLE:-0}" -eq 0 ]; then
    TARGET_WINDOW=$(aerospace list-windows --workspace "$TARGET_WS" --format '%{window-id}' 2>/dev/null | head -n 1)
    if [ -n "$TARGET_WINDOW" ]; then
      aerospace focus --window-id "$TARGET_WINDOW"
    fi
  fi

  # Restore XDR workspace if displaced by Arc activation during cross-monitor switch.
  # After the switch, Arc's last-focused is now the target (not Gmail),
  # so the re-focus back to target won't displace XDR again.
  if [ "$CROSS_MONITOR" = true ] && [ -n "$SAVED_XDR_WS" ] && [ "$SAVED_XDR_WS" != "$TARGET_WS" ]; then
    sleep 0.1
    CURRENT_XDR_WS=$(aerospace list-workspaces --visible --monitor "$XDR_ID" 2>/dev/null)
    if [ "$CURRENT_XDR_WS" != "$SAVED_XDR_WS" ]; then
      XDR_WINDOW=$(aerospace list-windows --workspace "$SAVED_XDR_WS" --format '%{window-id}' 2>/dev/null | head -n 1)
      if [ -n "$XDR_WINDOW" ]; then
        aerospace focus --window-id "$XDR_WINDOW"
        aerospace workspace "$TARGET_WS"
      fi
    fi
  fi

  "$SCRIPT_DIR/workspace-mode/auto-config.aerospace.sh" W
fi
