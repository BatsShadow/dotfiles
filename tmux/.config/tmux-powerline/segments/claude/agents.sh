# shellcheck shell=bash

# Refresh the blocked-agent list, but only when there is something the session
# files cannot answer on their own.
#
# For a background session the file status is conclusive in two cases out of
# three: busy means it is running and therefore not blocked, waiting is
# authoritative as written. Only idle is ambiguous -- a background agent blocked
# on input records itself as idle, because the file has no value for the
# condition -- and `claude agents --json` is the only thing that can tell the
# two apart. That call costs ~290ms of node startup, so it is worth some care
# about when it happens.
#
# The answer is valid for exactly the ambiguous set it was computed against.
# That is what distinguishes "asked, nothing is blocked" from "not yet asked":
# an empty list alone cannot say which.
#
# Never blocks. The caller uses whatever the cache already holds, so the blocked
# state can lag by a tick while everything read from the session files stays
# current.
__cc_refresh_blocked() {
	local cache="$1" amb_fp="$2" age stored

	# Nothing idle in the background means nothing can be blocked, so the list
	# is empty by construction and the binary is never spawned at all.
	#
	# Both writes are gated on the cache existing. This is the steady state -- it
	# runs every status-interval, forever, on a machine with no idle background
	# agents -- and an unconditional set-option here would make tmux redraw the
	# status line once a second for nothing, which is the same reason every write
	# in __cc_sync_windows is diff-gated.
	#
	# The cache is removed rather than truncated. An answer of "nothing blocked"
	# is a legitimately empty file, so gating on size would leave the stored
	# fingerprint behind and let the settled-answer check below suppress the next
	# refresh for a whole TTL -- a background agent that became blocked in the
	# meantime would read as plain idle. With the file gone, __cc_file_age yields
	# nothing and the refresh is forced the moment the set comes back.
	if [ -z "$amb_fp" ]; then
		if [ -e "$cache" ]; then
			rm -f "$cache" 2>/dev/null
			tmux set-option -g @cc_bg_amb "" 2>/dev/null
		fi
		return 0
	fi

	# show-options -gv errors on an option that has never been set, which is
	# exactly the first-run case, so failure is read as "no stored answer".
	stored=$(tmux show-options -gv @cc_bg_amb 2>/dev/null)
	age=$(__cc_file_age "$cache")

	# A settled answer for this exact set. The backstop still forces a refresh
	# eventually, so a transition the file polling failed to see cannot hide
	# indefinitely.
	if [ "$stored" = "$amb_fp" ] && [ -n "$age" ] &&
		[ "$age" -lt "$TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_AGENTS_TTL" ]; then
		return 0
	fi

	# Directory create is atomic, so only one refresh can be in flight even
	# though a new copy of this script runs every status-interval.
	local lock="${cache}.lock"

	# The lock is released by an EXIT trap, which never runs if the shell
	# holding it is SIGKILLed, and the `claude` call below is only run under
	# `timeout` when timeout happens to be installed. Either way a lock can be
	# left behind for good -- and once it is, every later call returns here,
	# the blocked list never refreshes again, and a background agent blocked on
	# input reads as idle forever with nothing to say why. A lock older than
	# several TTLs cannot belong to a refresh that is still going anywhere.
	local lock_age
	lock_age=$(__cc_file_age "$lock")
	if [ -n "$lock_age" ] &&
		[ "$lock_age" -gt $((TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_AGENTS_TTL * 5)) ]; then
		rmdir "$lock" 2>/dev/null
	fi

	mkdir "$lock" 2>/dev/null || return 0

	# The subshell MUST have its stdout redirected. tmux reads a #() command
	# until EOF, so a child still holding the inherited pipe would stall the
	# status bar.
	(
		trap 'rmdir "$lock" 2>/dev/null' EXIT
		local out=""
		if command -v timeout >/dev/null 2>&1; then
			out=$(timeout 10 "$TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_AGENTS_CMD" agents --json 2>/dev/null)
		else
			out=$("$TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_AGENTS_CMD" agents --json 2>/dev/null)
		fi

		if [ -n "$out" ]; then
			# Only agents that still have a pid. A parked conversation with no
			# process cannot be attributed to a window, and several of those
			# are weeks old -- permanently amber entries would just train the
			# eye to ignore the colour.
			#
			# jq is tested rather than assumed. The redirect creates the temp
			# file before jq ever runs, so a jq failure -- an output shape that
			# changed under us, most likely -- leaves an empty file behind, and
			# installing that as the cache would turn the whole feature off
			# with no signal at all. On failure keep whatever the cache already
			# holds; a stale answer beats a silently empty one.
			if printf '%s' "$out" |
				jq -r '.[]? | select(.kind == "background" and .state == "blocked" and .pid != null) | .pid' \
					2>/dev/null >"${cache}.$$"; then
				mv -f "${cache}.$$" "$cache" 2>/dev/null || rm -f "${cache}.$$"
			else
				rm -f "${cache}.$$"
				# Same throttle reset as the no-output branch below.
				touch "$cache" 2>/dev/null
			fi
		else
			# Reset the throttle even on failure, so a broken CLI cannot turn
			# into a refresh attempt every single status-interval.
			touch "$cache" 2>/dev/null
		fi

		# Stored in both branches, for the same reason the failure branch
		# touches the cache: a CLI that keeps failing must not be retried on
		# every tick.
		tmux set-option -g @cc_bg_amb "$amb_fp" 2>/dev/null
	) >/dev/null 2>&1 &

	return 0
}
