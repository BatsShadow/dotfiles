#!/usr/bin/env bash
# Workspace-mode app key dispatcher. Tile mode's keys go to tile-mode/app.sh.
#
#   1. Count windows on the target workspace
#   2. If already on the target workspace → run --on-focus action (if provided)
#   3. If no windows on the target workspace → launch app, then switch
#      (unless --no-launch: switch to the empty workspace without launching, or
#      the app already has a window on some other workspace: switch and say so)
#   4. Otherwise → switch to workspace and auto-config gaps
#
# With --role (browser windows, see window-roles.sh):
#   1. Find the role's window: remembered, else adopted from the workspace
#   2. None → launch the app if it isn't running and look again, then open a
#      new window, remember it and move it to the workspace
#   3. Already focused on it → run --on-focus action
#   4. It was moved to another workspace → say where, switch anyway
#   5. Otherwise → switch to the workspace and focus that window
#
# Options:
#   --app-id <id>         Bundle ID to match (required)
#   --app-name <name>     App name for messages (required)
#   --workspace <name>    Workspace name (required)
#   --on-focus <cmd>      Command to run if already on target workspace/window
#   --role <role>         Use the remembered window for this role
#   --no-launch           Never start the app. For apps that should only ever be
#                         opened by something else (Zoom, from a meeting link):
#                         the key navigates to them but cannot summon them.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/window-roles.sh"

APP_ID=""
APP_NAME=""
WORKSPACE=""
ON_FOCUS=""
ROLE=""
NO_LAUNCH=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-id) APP_ID="$2"; shift 2 ;;
    --app-name) APP_NAME="$2"; shift 2 ;;
    --workspace) WORKSPACE="$2"; shift 2 ;;
    --on-focus) ON_FOCUS="$2"; shift 2 ;;
    --role) ROLE="$2"; shift 2 ;;
    --no-launch) NO_LAUNCH=1; shift ;;
    *) shift ;;
  esac
done

TARGET_WS="${WORKSPACE:?dispatch.sh: --workspace is required}"

CURRENT_WS=$(aerospace list-workspaces --focused 2>/dev/null)

# Check if the target workspace has any windows
WS_WINDOW_COUNT=$(aerospace list-windows --workspace "$TARGET_WS" --format '%{window-id}' 2>/dev/null | grep -c .)

ROLE_WINDOW=""
if [ -n "$ROLE" ]; then
  ROLE_WINDOW=$(role_find "$ROLE" "$APP_ID")
  if [ -z "$ROLE_WINDOW" ] && role_launch "$APP_ID"; then
    ROLE_WINDOW=$(role_find "$ROLE" "$APP_ID")
  fi
  if [ -z "$ROLE_WINDOW" ]; then
    echo "No $ROLE window for $APP_NAME, opening one..."
    ROLE_WINDOW=$(role_create "$ROLE" "$APP_ID")
    [ -n "$ROLE_WINDOW" ] && aerospace move-node-to-workspace --window-id "$ROLE_WINDOW" "$TARGET_WS"
  elif [ "$ROLE_WINDOW" = "$(aerospace list-windows --focused --format '%{window-id}' 2>/dev/null)" ]; then
    if [ -n "$ON_FOCUS" ]; then
      echo "Already on the $ROLE window, running on-focus action..."
      eval "$ON_FOCUS"
    fi
    exit 0
  fi

  # Moved by hand to another workspace: leave it where it was put and say
  # where, the same as the stray-window notice below.
  ROLE_WS=$(aerospace list-windows --all --format '%{window-id}|%{workspace}' 2>/dev/null |
    awk -F'|' -v id="$ROLE_WINDOW" '$1 == id { print $2; exit }')
  if [ -n "$ROLE_WINDOW" ] && [ "$ROLE_WS" != "$TARGET_WS" ]; then
    echo "$APP_NAME's $ROLE window is on $ROLE_WS."
    MSG="$APP_NAME's $ROLE window is on the $ROLE_WS space"
    osascript -e "display notification \"${MSG//\"/\\\"}\" with title \"AeroSpace\"" &
    ROLE_WINDOW=""
  fi
fi

# Already on this workspace → run secondary action
if [ -z "$ROLE" ] && [ "$CURRENT_WS" = "$TARGET_WS" ]; then
  if [ -n "$ON_FOCUS" ]; then
    echo "Already on $TARGET_WS, running on-focus action..."
    eval "$ON_FOCUS"
  fi
  exit 0
fi

# Target workspace is empty → launch the app. Under --no-launch we still make
# the trip to the (empty) workspace; only the launch is skipped.
if [ -z "$ROLE" ] && [ "${WS_WINDOW_COUNT:-0}" -eq 0 ] && [ "$NO_LAUNCH" -eq 0 ]; then
  # A window moved by hand to another workspace leaves this one empty, and
  # `open -b` on an app that is already running cannot conjure a second
  # window: it just activates the one that moved, dragging the screen to that
  # workspace for an instant before the switch below pulls it back. The window
  # looks like it flashed and vanished, with no hint of where it went. So say
  # where it went and leave it where the user put it.
  STRAY_WS=$(aerospace list-windows --all --format '%{app-bundle-id}|%{workspace}' 2>/dev/null |
    awk -F'|' -v id="$APP_ID" '
      $1 == id && !seen[$2]++ { ws[++n] = $2 }
      END {
        for (i = 1; i <= n; i++) {
          list = list (i == 1 ? "" : i == n ? " and " : ", ") ws[i]
        }
        print list
      }')

  if [ -n "$STRAY_WS" ]; then
    echo "$APP_NAME has no window on $TARGET_WS; it is on $STRAY_WS."
    SPACE_WORD="space"
    case "$STRAY_WS" in *" and "*) SPACE_WORD="spaces" ;; esac
    MSG="$APP_NAME is on the $STRAY_WS $SPACE_WORD"
    osascript -e "display notification \"${MSG//\"/\\\"}\" with title \"AeroSpace\"" &
  else
    echo "Target app/window not found, launching..."
    open -b "$APP_ID"
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
# workspace from invisible to visible. A role names its window, so focus it.
if [ -n "$ROLE_WINDOW" ]; then
  aerospace focus --window-id "$ROLE_WINDOW"
elif [ "${TARGET_WAS_VISIBLE:-0}" -eq 0 ]; then
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
