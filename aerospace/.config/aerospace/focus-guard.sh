#!/usr/bin/env bash
# Hold focus on a window through Crest's activation. Sourced by dispatch.sh.
#
# Activating Crest makes it raise its own last active window, around 450ms
# after AeroSpace has focused the window it was asked for. Measured 2026-10-30
# with Browser showing on the built-in screen and YouTube switched to on the
# XDR: a bare `aerospace workspace YouTube` ended on the Browser window, and a
# `focus --window-id` sent straight after the switch still lost 2 runs in 3,
# because the theft lands after it. It needs Crest's last window to be on
# screen. With Gmail on a hidden workspace instead, 3 runs of 3 kept focus.
#
# So focus the window, wait for the theft and undo it once. Crest is the
# active app by then and does not steal again: one refocus held in 5 runs of
# 5. The guard waits only on a Crest window with two monitors up, and only
# counts a theft that lands on another Crest window on the other monitor.
# Anything else is the user moving focus during the wait, so a quick move
# between WezTerm windows, or between two windows on one screen, is left
# alone. A newer dispatch.sh takes the token, so its own Crest window is not
# pulled back to this one.
#
# Arc did the same, which is why dispatch.sh used to focus the workspace's
# first window by hand. That beat the theft and broke sticky focus: the first
# window is whichever app sorts first by name.
# Bash 3.2 safe.

FOCUS_GUARD_TOKEN="${FOCUS_GUARD_TOKEN:-${TMPDIR:-/tmp}/aerospace-focus-guard}"
FOCUS_GUARD_TRIES="${FOCUS_GUARD_TRIES:-12}" # x ~70ms, past the ~450ms theft
FOCUS_GUARD_APP="${FOCUS_GUARD_APP:-com.pauldavis.crest}"

# focus_guard_claim: mark this run as the newest. Call before switching.
focus_guard_claim() { echo $$ >"$FOCUS_GUARD_TOKEN"; }

# focus_guard <window-id>: focus a window, and put focus back once if Crest
# raises one of its windows on another monitor.
focus_guard() {
  local want="$1" app mon id app_now mon_now n=0
  [ -n "$want" ] || return 0
  IFS='|' read -r app mon <<<"$(aerospace list-windows --all \
    --format '%{window-id}|%{app-bundle-id}|%{monitor-id}' 2>/dev/null |
    awk -F'|' -v id="$want" '$1 == id { print $2 "|" $3; exit }')"
  [ "$app" = "$FOCUS_GUARD_APP" ] || return 0
  aerospace focus --window-id "$want" 2>/dev/null || return 0
  [ "$(aerospace list-monitors --count 2>/dev/null)" -ge 2 ] 2>/dev/null || return 0
  while [ "$n" -lt "$FOCUS_GUARD_TRIES" ]; do
    sleep 0.05
    [ "$(cat "$FOCUS_GUARD_TOKEN" 2>/dev/null)" = "$$" ] || return 0
    IFS='|' read -r id app_now mon_now <<<"$(aerospace list-windows --focused \
      --format '%{window-id}|%{app-bundle-id}|%{monitor-id}' 2>/dev/null)"
    if [ "$id" != "$want" ]; then
      # Crest on the other monitor is the theft. Anything else is the user.
      if [ "$app_now" = "$app" ] && [ "$mon_now" != "$mon" ]; then
        aerospace focus --window-id "$want" 2>/dev/null
      fi
      return 0
    fi
    n=$((n + 1))
  done
}
