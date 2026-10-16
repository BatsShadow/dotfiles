#!/usr/bin/env bash
# Show Space N, and optionally tab N in it, in Crest's front window.
# Usage: crest-show-tab.sh <space|-> [tab]     (- keeps the current Space)
#
# Crest has no working AppleScript (0.8.1): it ships Chromium's dictionary,
# but Crest draws its own windows, so `count windows` fails with -10000.
# Issue #380 in pauljoda/Crest tracks a real one. Until then the only way in
# is Crest's default shortcuts, Ctrl-N for Space N and Cmd-N for tab N, sent
# to whichever Crest window is in front. Callers focus the right window first.
#
# crest-keys.sh sends the keys, and says why they are not System Events
# keystrokes.

SPACE=${1:?"Usage: crest-show-tab.sh <space|-> [tab]"}
TAB=${2:-}
[ "$SPACE" = - ] && SPACE=""

exec "$(dirname "${BASH_SOURCE[0]}")/crest-keys.sh" ${SPACE:+"ctrl-$SPACE"} ${TAB:+"cmd-$TAB"}
