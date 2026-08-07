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

	# Every branch below forks and returns immediately rather than waiting on
	# the notifier: this runs on the status-interval path, and terminal-notifier
	# alone measures ~0.5s just to start, which is most of a redraw's budget.
	# The subshell's stdout/stderr MUST be redirected before the fork, exactly
	# as __cc_refresh_blocked does in agents.sh -- tmux reads a #() command
	# until EOF, so a detached child still holding the inherited pipe would
	# stall the status bar as badly as running synchronously, only more
	# confusingly.
	if [ -n "$TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_NOTIFY_CMD" ]; then
		( "$TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_NOTIFY_CMD" "$window" "$subtitle" ) >/dev/null 2>&1 &
		return 0
	fi

	if command -v terminal-notifier >/dev/null 2>&1; then
		local goto="${BASH_SOURCE[0]%/*}/goto.sh"

		# terminal-notifier runs -execute through a shell when the notification
		# is clicked, and every value below is quoted with plain single quotes
		# in that argument. window is #{session_name}:#{window_index} straight
		# off tmux -- session names are user-controlled, so an apostrophe in
		# one is entirely plausible -- and goto is a filesystem path, never
		# provably free of one either. Inside a single-quoted string a literal
		# ' cannot be escaped in place; it has to close the quote, contribute
		# an escaped quote, then reopen: '\''. Skipping this for any one of
		# the three turns a stray apostrophe into arbitrary shell source.
		local shquote_window="${window//\'/\'\\\'\'}"
		local shquote_goto="${goto//\'/\'\\\'\'}"
		local shquote_app="${TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_TERM_APP//\'/\'\\\'\'}"

		# -group keyed on the window so a repeat replaces its predecessor
		# rather than stacking another card for the same session.
		(
			terminal-notifier \
				-title "${label} ${window}" \
				-message "$subtitle" \
				-group "cc-${window}" \
				-execute "'${shquote_goto}' '${shquote_window}' '${shquote_app}'"
		) >/dev/null 2>&1 &
		return 0
	fi

	# Quote-safe: both values reach osascript as AppleScript string literals,
	# so any embedded double quote would otherwise end the literal early.
	# Backslashes must be escaped first, before double quotes: escaping the
	# quotes first would plant fresh backslashes that the backslash pass would
	# then double-escape. waitingFor echoes tool and shell text, so a
	# backslash landing right before the closing quote -- which would escape
	# that quote and run the literal on into the surrounding script -- is a
	# realistic case, not just a theoretical one.
	local t="${label} ${window}" m="$subtitle"
	t="${t//\\/\\\\}"
	m="${m//\\/\\\\}"
	t="${t//\"/\\\"}"
	m="${m//\"/\\\"}"
	( osascript -e "display notification \"${m}\" with title \"${t}\"" ) >/dev/null 2>&1 &
	return 0
}
