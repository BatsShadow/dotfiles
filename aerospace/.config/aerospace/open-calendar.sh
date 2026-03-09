#!/usr/bin/env bash
# Activate Calendar app and set it to week view on today
osascript -e '
activate application "Calendar"
tell application "System Events"
  tell process "Calendar"
    click menu item "Calendar" of menu 1 of menu bar item "Window" of menu bar 1
    click menu item "By Week" of menu 1 of menu bar item "View" of menu bar 1
    click menu item "Go to Today" of menu 1 of menu bar item "View" of menu bar 1
  end tell
end tell
'
