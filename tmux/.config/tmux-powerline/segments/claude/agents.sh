# shellcheck shell=bash

# Kick a background refresh of the blocked-agent list if the cache has aged
# out. Never blocks: the caller uses whatever the cache already holds, so the
# blocked state can lag by up to TTL seconds while everything sourced from the
# session files stays current.
#
# The subshell MUST have its stdout redirected. tmux reads a #() command until
# EOF, so a child still holding the inherited pipe would stall the status bar.
__cc_refresh_blocked() {
	local cache="$1" age
	age=$(__cc_file_age "$cache")
	[ -n "$age" ] && [ "$age" -lt "$TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_AGENTS_TTL" ] && return 0

	# Directory create is atomic, so only one refresh can be in flight even
	# though a new copy of this script runs every status-interval.
	local lock="${cache}.lock"
	mkdir "$lock" 2>/dev/null || return 0

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
			printf '%s' "$out" \
				| jq -r '.[]? | select(.kind == "background" and .state == "blocked" and .pid != null) | .pid' \
					2>/dev/null > "${cache}.$$"
			mv -f "${cache}.$$" "$cache" 2>/dev/null || rm -f "${cache}.$$"
		else
			# Reset the throttle even on failure, so a broken CLI cannot turn
			# into a refresh attempt every single status-interval.
			touch "$cache" 2>/dev/null
		fi
	) >/dev/null 2>&1 &

	return 0
}
