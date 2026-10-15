-- Select a tab by name in a named Arc space, in the front window
-- Usage: osascript arc-select-named-tab.scpt <space-name> <tab-name>
-- Example: osascript arc-select-named-tab.scpt Work PRs

on run argv
  set spaceName to item 1 of argv
  set tabName to item 2 of argv

  tell application "Arc"
    tell front window
      tell space spaceName
        tell first tab whose name is tabName to select
      end tell
    end tell
    activate
  end tell
end run
