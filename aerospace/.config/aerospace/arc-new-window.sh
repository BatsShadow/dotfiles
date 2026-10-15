#!/usr/bin/env bash
# Open a new Arc window showing a role's tab. role_create in window-roles.sh
# calls this, then finds the new window's id and remembers it.
# Usage: arc-new-window.sh Browser|Email|YouTube
#
# The tabs match what each role's key shows on a second press: Email opens on
# the pinned Gmail tab (toggle-email-pin.sh), YouTube on tab 1 of space 3
# (arc-select-tab.scpt), Browser on the Work space.

case "$1" in
  Browser) SHOW='tell space "Work" to focus' ;;
  Email)   SHOW='tell first tab whose name contains "Gmail" and location is "topApp" to select' ;;
  YouTube) SHOW='tell space 3
      tell tab 1 to select
    end tell' ;;
  *) echo "arc-new-window.sh: unknown role '$1'" >&2; exit 1 ;;
esac

osascript -e "
tell application \"Arc\"
  make new window
  tell front window
    $SHOW
  end tell
  activate
end tell
"
