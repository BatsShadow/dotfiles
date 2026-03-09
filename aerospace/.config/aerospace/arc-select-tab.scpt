-- Select a tab in a specific Arc space
-- Usage: osascript arc-select-tab.scpt <space-index> <tab-index>
-- Example: osascript arc-select-tab.scpt 3 1  (first tab in space 3)

on run argv
  set spaceIndex to item 1 of argv as integer
  set tabIndex to item 2 of argv as integer

  tell application "Arc"
    tell front window
      tell space spaceIndex
        tell tab tabIndex to select
      end tell
    end tell
    activate
  end tell
end run
