#!/bin/bash
# The sessionizer calls this right before it opens a worktree's windows, to
# pull in the other machine's work first. It cannot wait indefinitely for
# that, so it stops waiting at a cap, but it never kills the run: one killed
# between a checkout and the lay after it left the worktree at the other
# machine's head without its uncommitted work, and keeping that side in the
# picker then pushed the half state back over the other machine.
#
#   open.sh <dir>

SRCSYNC_BIN="${SRCSYNC_BIN:-$HOME/.config/srcsync/srcsync.sh}"
[ -e "$SRCSYNC_BIN" ] || exit 0

TIMEOUT="${SRCSYNC_OPEN_TIMEOUT:-10}"

# Its own process group and no hangup, so neither a ctrl-c here nor the popup
# closing reaches it. auto logs to auto.log, so nothing needs its output.
set -m
(
	trap '' HUP
	exec /bin/bash "$SRCSYNC_BIN" auto open "$1"
) </dev/null >/dev/null 2>&1 &
cmd_pid=$!
set +m

n=0
while kill -0 "$cmd_pid" 2>/dev/null && [ "$n" -lt $((TIMEOUT * 10)) ]; do
	sleep 0.1
	n=$((n + 1))
done

exit 0
