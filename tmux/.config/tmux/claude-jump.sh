#!/usr/bin/env bash
# Jump to a window running Claude, showing what each one is waiting on.
#
# The status bar says how many need you; the notification says which one, once,
# and only if you saw it. Neither gets you there, and neither survives being
# away for an hour. This does: every Claude across every session, most demanding
# first, with the actual question beside the row.
#
# The question comes from the marker file the hook wrote -- see
# claude/.claude/hooks/claude-waiting.sh. That text is the entire reason to list
# these rather than just count them: knowing that two sessions want you is not
# the same as knowing one wants a code review and the other wants a yes.
#
# Sessions are not the unit here, windows are, matching the status bar and the
# notification click target. Selecting switches the client to the session and
# then selects the window, because a session can hold several and landing on the
# wrong one is the failure this is meant to remove.

export PATH="/opt/homebrew/bin:$PATH"

SESSIONS_DIR="${CC_SESSIONS_DIR:-$HOME/.claude/sessions}"
JOBS_DIR="${CC_JOBS_DIR:-$HOME/.claude/jobs}"
MARKS_DIR="${CC_WAITING_DIR:-$HOME/.claude/waiting}"

HERE="${BASH_SOURCE[0]%/*}"
COLLECT="${HERE}/../tmux-powerline/segments/claude/collect.sh"

# Degrades to an unstyled list rather than failing to open, same as the other
# pickers. Without the helper there are no colours; without collect there is
# nothing to list at all, which is worth saying out loud.
if [[ -r "${HERE}/claude-status.sh" ]]; then
	# shellcheck source=claude-status.sh
	source "${HERE}/claude-status.sh"
fi

if [[ ! -r "$COLLECT" ]]; then
	echo "claude-jump: cannot read ${COLLECT}"
	sleep 2
	exit 1
fi
# shellcheck disable=SC1090
source "$COLLECT"

raw=$(__cc_collect "$SESSIONS_DIR" "$JOBS_DIR" "$MARKS_DIR" 2>/dev/null)

# TORN is a read that could not be trusted and EMPTY is a clean read of nothing.
# Both mean there is no list to show, and both are ordinary rather than errors.
if [[ -z "$raw" || "$raw" == "TORN" || "$raw" == "EMPTY" ]]; then
	echo "No Claude sessions running."
	sleep 1
	exit 0
fi

# What each window is waiting on, resolved from the pid that won it, for every
# window at once.
#
# This was a jq per row, which is the wrong unit: jq costs ~19ms to start and
# essentially nothing to answer, so eighteen windows spent ~350ms learning what
# one invocation over the whole directory reports in 19ms. Reading the marker
# is now the shell's own `read` rather than a `cut` and a `head`, and the
# lookup at the call site is an array subscript rather than a command
# substitution -- three more processes a row that bought nothing.
#
# Still only on a keypress, so none of this touches the status-interval path.
declare -A CC_ASK=()
cc_load_asks() {
	local file sid pid text

	while IFS=$'\t' read -r file sid; do
		[[ -n "$sid" && -r "${MARKS_DIR}/${sid}" ]] || continue

		pid="${file##*/}"
		pid="${pid%.json}"

		# `type<TAB>text`, one line, as claude-waiting.sh writes it. Stripping
		# to the first tab keeps the text's own tabs and leading spaces, and
		# yields the whole line if there is no tab at all -- both of which are
		# what the `cut -f2-` here used to do.
		IFS= read -r text <"${MARKS_DIR}/${sid}"
		text="${text#*$'\t'}"
		[[ -n "$text" ]] && CC_ASK["$pid"]="$text"
	done < <(jq -r '[input_filename, (.sessionId // empty)] | @tsv' \
		"${SESSIONS_DIR}"/*.json 2>/dev/null)
}
cc_load_asks

current=""
[[ -n "${TMUX:-}" ]] && current=$(tmux display-message -p '#S:#I')

selected=$(
	{
		while read -r kind window state pid; do
			[[ "$kind" == "WIN" ]] || continue

			case "$state" in
			waiting) rank=1 ;;
			busy) rank=2 ;;
			*) rank=3 ;;
			esac

			glyph="$CC_BLANK" color="${CC_C_LIVE-}"
			case "$state" in
			waiting)
				glyph="${CC_G_WAIT} "
				color="${CC_C_WAIT-}"
				;;
			busy)
				glyph="${CC_G_BUSY} "
				color="${CC_C_BUSY-}"
				;;
			*) glyph="${CC_G_IDLE} " ;;
			esac

			# The window you are standing in is still listed -- leaving it out
			# would make the list disagree with the count on the bar -- but it
			# is marked, so selecting it knowingly is a no-op rather than a
			# surprise.
			here=""
			[[ "$window" == "$current" ]] && here=" ${CC_C_DIM-}(here)${CC_C_OFF-}"

			ask="${CC_ASK[$pid]:-}"
			[[ -n "$ask" ]] && ask="${CC_C_DIM-}${ask:0:90}${CC_C_OFF-}"

			# rank leads the line for the sort below and is stripped after.
			printf '%s\t%s%s%s%s%s\t%s\n' \
				"$rank" \
				"${color}${glyph}${window}${CC_C_OFF-}" \
				"$here" \
				"${ask:+  }" "$ask" "" \
				"$window"
		done <<<"$raw"
		# Waiting first, then busy, then idle: the order the bar already
		# implies, and the order attention is actually owed in.
	} | sort -t$'\t' -k1,1n | cut -f2- |
		fzf --ansi --delimiter='\t' --with-nth=1 --accept-nth=2 \
			--ghost="claude" \
			--prompt="claude> "
)

[[ -z "$selected" ]] && exit 0

# Session and window, not just session. switch-client lands on whichever window
# was last active there, which is precisely the wrong one when a session holds
# several and only one of them is asking.
session="${selected%%:*}"
tmux switch-client -t "$session" 2>/dev/null || tmux attach -t "$session"
tmux select-window -t "$selected"
