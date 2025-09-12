#!/usr/bin/env bash

WORKSPACE="$1"
DESIRED_SPACE="$2"
DESIRED_TAB="$3"
WINDOWS=$(aerospace list-windows --workspace $WORKSPACE --format "%{app-name}" --json)
if ! echo $WINDOWS | grep -q '"app-name" : "Arc"'; then
  # new Arc windows always open in workspace N per Aerospace, so just start there
  aerospace workspace N
  SCRIPT='
    tell application "Arc" to activate
    tell application "Arc"
      make new window
      delay 0.25
      tell application "System Events"
        -- Escape to close the tab location box
        key code 53
      end tell
      tell first window
        tell space "'$DESIRED_SPACE'"
          focus
          tell first tab whose name is "'$DESIRED_TAB'" to select
        end tell
      end tell
    end tell
  '
  osascript -e "$SCRIPT"
  aerospace move-node-to-workspace $WORKSPACE
fi
aerospace workspace $WORKSPACE
