#!/usr/bin/env bash
# Workspace-mode app key dispatcher. Tile mode's keys go to tile-mode/app.sh.
#
#   1. Count windows on the target workspace
#   2. If already on the target workspace → run --on-focus action (if provided)
#   3. If no windows on the target workspace → launch app, then switch
#      (unless --no-launch: switch to the empty workspace without launching, or
#      the app already has a window on some other workspace: switch and say so)
#   4. Otherwise → switch to workspace, its saved gaps loaded in the same
#      step (workspace-mode/gaps.sh), or auto-config after if it has none
#
# With --role (browser windows, see window-roles.sh):
#   1. Find the role's window: remembered, else adopted from the workspace
#   2. None → launch the app if it isn't running and look again, then open a
#      new window, remember it and move it to the workspace
#   3. Already focused on it → run --on-focus action
#   4. It was moved to another workspace → say where, switch anyway
#   5. Already on the workspace → focus the role's window
#   6. Otherwise → switch to the workspace, like a key without a role
#
# A switch is sticky: it lands on the window last focused there, which
# AeroSpace remembers per workspace. Only a window created just now is
# focused instead. focus-guard.sh holds that window against Crest raising
# its own last window on activation.
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
source "$SCRIPT_DIR/focus-guard.sh"
source "$SCRIPT_DIR/workspace-mode/gaps.sh"

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
CREATED=""
if [ -n "$ROLE" ]; then
  ROLE_WINDOW=$(role_find "$ROLE" "$APP_ID")
  if [ -z "$ROLE_WINDOW" ] && role_launch "$APP_ID"; then
    ROLE_WINDOW=$(role_find "$ROLE" "$APP_ID")
  fi
  if [ -z "$ROLE_WINDOW" ]; then
    echo "No $ROLE window for $APP_NAME, opening one..."
    ROLE_WINDOW=$(role_create "$ROLE" "$APP_ID")
    [ -n "$ROLE_WINDOW" ] && aerospace move-node-to-workspace --window-id "$ROLE_WINDOW" "$TARGET_WS"
    CREATED=$ROLE_WINDOW
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

  # A second press, once the workspace is up: go to the role's window.
  if [ "$CURRENT_WS" = "$TARGET_WS" ]; then
    focus_guard_claim
    focus_guard "$ROLE_WINDOW"
    exit 0
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

focus_guard_claim

# Gaps first, then the switch, so the workspace is drawn once at its own
# gaps rather than at the old ones and then resized (see gaps.sh).
gaps_prepare "$TARGET_WS"
PREPARED=$?
if [ "$PREPARED" -eq 0 ] && [ "$GAPS_RELOAD" = 1 ]; then
  aerospace eval "reload-config; workspace $TARGET_WS"
else
  aerospace workspace "$TARGET_WS"
fi

# The window AeroSpace brought back. Read it now: Crest's theft lands about
# 450ms later, and in 6 runs of 6 this read came first. If it already landed,
# the focus is off this workspace and the role's window stands in.
WANT=$(aerospace list-windows --focused --format '%{window-id}|%{workspace}' 2>/dev/null |
  awk -F'|' -v ws="$TARGET_WS" '$2 == ws { print $1 }')
[ -n "$CREATED" ] && WANT=$CREATED
[ -n "$WANT" ] || WANT=$ROLE_WINDOW

# No saved mode to apply ahead: count its columns now that it shows.
[ "$PREPARED" -eq 1 ] && "$SCRIPT_DIR/workspace-mode/auto-config.aerospace.sh" W
focus_guard "$WANT"
