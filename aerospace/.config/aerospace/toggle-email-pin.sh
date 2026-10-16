#!/usr/bin/env bash
# Toggle the Email window between Gmail and Messages, tabs 1 and 2 of Crest's
# Work Space. The window title is the shown tab's title, so it says which one
# is up. The window is already on Work, so only the tab key is sent.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TITLE=$(aerospace list-windows --focused --format '%{window-title}' 2>/dev/null)

if echo "$TITLE" | grep -qi "Messages"; then
  "$SCRIPT_DIR/crest-show-tab.sh" - 1
else
  "$SCRIPT_DIR/crest-show-tab.sh" - 2
fi
