#!/usr/bin/env bash
# Tell srcsync a turn or session ended, so it can publish the worktree.
#
# Backgrounded because auto's own work (up to a hub clone) would otherwise
# hold up the next turn; constraints.md caps every hook at one second.
# Detaching by exiting a subshell that already put the job in the background
# is what makes the hook return before that work is done, not after.
#
# auto is off by default, so this firing on every turn costs one log line
# until the user opts in.
#
#   <hook payload on stdin> | srcsync-hook.sh

set -u

SRCSYNC_BIN="${SRCSYNC_BIN:-${HOME}/.config/srcsync/srcsync.sh}"

command -v jq >/dev/null 2>&1 || exit 0
[ -e "$SRCSYNC_BIN" ] || exit 0

payload=$(cat)

read -r hook_event cwd <<<"$(printf '%s' "$payload" | jq -r '
	[(.hook_event_name // "-"), (.cwd // "-")] | @tsv' 2>/dev/null)"

case "${hook_event:-}" in
Stop) event=stop ;;
SessionEnd) event=end ;;
*) exit 0 ;;
esac

[ -n "${cwd:-}" ] && [ "$cwd" != "-" ] || exit 0

(/bin/bash "$SRCSYNC_BIN" auto "$event" "$cwd" </dev/null >/dev/null 2>&1 &)

exit 0
