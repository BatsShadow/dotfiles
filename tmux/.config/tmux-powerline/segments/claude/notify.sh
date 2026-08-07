# shellcheck shell=bash
# macOS notification for a Claude session that has started waiting on you.
#
# Delivery order: an explicit NOTIFY_CMD if configured (which is how the tests
# drive this), then terminal-notifier, then osascript. terminal-notifier is
# preferred because it is the only one of the three that can carry a click
# action, and with thirty-odd sessions live, landing in the right window matters
# more than being told which one it is.
#
# osascript exits 0 whether or not the notification was actually shown -- if
# notifications are disabled for it in System Settings they are dropped
# silently, and nothing here can detect that.

__cc_notify() {
	local dir="$1"
	local -n __cc_notify_windows=$2
	local -n __cc_notify_pids=$3

	[ "${#__cc_notify_windows[@]}" -gt 0 ] || return 0

	local window pid subtitle
	for window in "${__cc_notify_windows[@]}"; do
		# Read waitingFor lazily, from the session that won this window. It is
		# only ever needed when a notification actually fires, so it stays off
		# the status-interval path entirely.
		subtitle=""
		pid="${__cc_notify_pids[$window]-}"
		if [ -n "$pid" ] && [ -r "${dir}/${pid}.json" ]; then
			subtitle=$(jq -r '.waitingFor // empty' "${dir}/${pid}.json" 2>/dev/null)
		fi
		[ -n "$subtitle" ] || subtitle="waiting on you"

		__cc_notify_one "$window" "$subtitle"
	done

	return 0
}

__cc_notify_one() {
	local window="$1" subtitle="$2"
	local label="$TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_LABEL"

	if [ -n "$TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_NOTIFY_CMD" ]; then
		"$TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_NOTIFY_CMD" "$window" "$subtitle" >/dev/null 2>&1
		return 0
	fi

	if command -v terminal-notifier >/dev/null 2>&1; then
		local goto="${BASH_SOURCE[0]%/*}/goto.sh"
		# -group keyed on the window so a repeat replaces its predecessor
		# rather than stacking another card for the same session.
		terminal-notifier \
			-title "${label} ${window}" \
			-message "$subtitle" \
			-group "cc-${window}" \
			-execute "'${goto}' '${window}' '${TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_TERM_APP}'" \
			>/dev/null 2>&1
		return 0
	fi

	# Quote-safe: both values reach osascript as AppleScript string literals,
	# so any embedded double quote would otherwise end the literal early.
	local t="${label} ${window}" m="$subtitle"
	t="${t//\"/\\\"}"
	m="${m//\"/\\\"}"
	osascript -e "display notification \"${m}\" with title \"${t}\"" >/dev/null 2>&1
	return 0
}
