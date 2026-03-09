#!/usr/bin/env bash
# Toggle between Gmail and Messages in Arc.
# If current window title contains "Gmail", switch to Messages, otherwise Gmail.

TITLE=$(aerospace list-windows --focused --format '%{window-title}' 2>/dev/null)

if echo "$TITLE" | grep -qi "Gmail"; then
  TAB_NAME="Messages"
else
  TAB_NAME="Gmail"
fi

osascript -e "
tell application \"Arc\"
  tell front window
    tell first tab whose name contains \"$TAB_NAME\" to select
  end tell
  activate
end tell
"
