#!/usr/bin/env bash
# Toggle between Gmail and Messages in Arc.
# If current window title contains "Messages", switch to Gmail, otherwise Messages.

TITLE=$(aerospace list-windows --focused --format '%{window-title}' 2>/dev/null)

if echo "$TITLE" | grep -qi "Messages"; then
  TAB_NAME="Gmail"
else
  TAB_NAME="Messages"
fi

osascript -e "
tell application \"Arc\"
  tell front window
    tell first tab whose name contains \"$TAB_NAME\" and location is \"topApp\" to select
  end tell
  activate
end tell
"
