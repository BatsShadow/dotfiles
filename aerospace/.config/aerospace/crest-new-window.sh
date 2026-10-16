#!/usr/bin/env bash
# Open a new Crest window showing a role's tab. role_create in window-roles.sh
# calls this, then finds the new window's id and remembers it.
# Usage: crest-new-window.sh Browser|Email|YouTube
#
# Crest can't make a window by script, so this presses Cmd-N with
# crest-keys.sh, the same way crest-show-tab.sh picks tabs.
# Tabs: Gmail and Messages are tabs 1 and 2 of the Work Space (Space 1), PRs
# is tab 4 of Work, YouTube is tab 1 of the YouTube Space (Space 3).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "$1" in
  Browser) SHOW=(1) ;;
  Email)   SHOW=(1 1) ;;
  YouTube) SHOW=(3 1) ;;
  *) echo "crest-new-window.sh: unknown role '$1'" >&2; exit 1 ;;
esac

"$SCRIPT_DIR/crest-keys.sh" cmd-n
# Wait for the new window to take focus before the Space keys go to it.
sleep 0.4
"$SCRIPT_DIR/crest-show-tab.sh" "${SHOW[@]}"
