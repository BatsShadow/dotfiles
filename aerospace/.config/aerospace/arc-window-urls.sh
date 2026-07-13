#!/usr/bin/env bash
# Emit one line per Arc window:  <window-title><TAB><active-tab-URL>
#
# Used by app.sh (--find-url / --exclude-url) to classify Arc windows by URL.
# Window titles follow the active tab's page title, so they are unreliable for
# role detection — a playing YouTube video's title is the video name, not
# "YouTube". The title is emitted as the join key back to AeroSpace windows
# (AeroSpace's %{window-title} == Arc's `name of window`).
# NOTE: `sep`/`nl` are bound OUTSIDE the `tell application "Arc"` block on
# purpose. Inside the tell, `tab` resolves to Arc's `tab` CLASS (a browser tab),
# not the AppleScript tab-character constant, and coerces to the literal string
# "tab" — which silently broke the <TAB> field separator this script promises.
osascript <<'APPLESCRIPT' 2>/dev/null
set sep to tab
set nl to linefeed
tell application "Arc"
  set out to ""
  repeat with w in windows
    set theName to ""
    set theURL to ""
    try
      set theName to name of w
    end try
    try
      set theURL to URL of active tab of w
    end try
    set out to out & theName & sep & theURL & nl
  end repeat
  return out
end tell
APPLESCRIPT
