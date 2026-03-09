#!/usr/bin/env bash
# Open a URL in a new Arc window.
# Usage: open-arc-url.sh <url>

URL=${1:?"Usage: open-arc-url.sh <url>"}

osascript -e "
tell application \"Arc\"
  make new window
  tell front window
    make new tab with properties {URL:\"$URL\"}
  end tell
  activate
end tell
"
