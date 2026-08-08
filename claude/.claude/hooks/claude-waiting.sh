#!/usr/bin/env bash
# Mark a Claude session as waiting on the user, for the tmux status bar.
#
# The problem this solves: a session that has asked an open-ended question is
# indistinguishable, in every file Claude Code writes, from one that has simply
# finished. Both report status "idle" with waitingFor null. Probing every hook
# payload confirmed the same holds for notifications -- an open-ended question
# and a completed turn produce a byte-identical sequence, right down to the
# notification text ("Claude is waiting for your input"):
#
#   UserPromptSubmit -> Stop -> Notification(idle_prompt, +60s)
#
# So notification_type cannot answer it. The one field that can is Stop's
# last_assistant_message, which is the full text of what Claude just said.
#
# The rule: the final paragraph contains a question mark, or asks the user to
# reply. Deliberately not "the message ends in ?", which misses a question with
# anything after it at all -- "Should I do X? I can also do Y." is a question,
# and the strict rule calls it a statement.
#
# It is a guess, so it is measured rather than trusted. Four verdicts are
# computed on every turn and all four are logged; the live rule is para OR ask.
# The rule itself, and the reasoning behind each pattern and window, is in
# waiting-rule.jq -- shared with the backfill so the two cannot drift.
#
# What matters here is that the losing rules are logged too. Whether para's
# known blind spot -- a question followed by a closing paragraph -- matters in
# practice is a question about how Claude actually writes, which no amount of
# reasoning settles. So tail2 is computed and recorded against every turn, and
# waiting-report.sh scores all four against the calls you mark wrong. Switching
# to it later is a one-word change.
#
# Timing is not free. idle_prompt is a fixed 60s timer (measured; documented
# nowhere), so a window turns amber a minute after Claude asks. There is no
# earlier signal -- Stop alone would light up every finished session.
#
# Two states, because "asked a question" and "you have not come back" are
# different facts and only their conjunction means waiting:
#
#   <sid>.pending   Stop said the last paragraph held a question
#   <sid>           idle_prompt then confirmed the user has not returned
#
# Only the second is read by the status bar. permission_prompt and the
# elicitation types skip the pending stage: those are Claude actively blocked,
# which needs no inference and no 60s wait.
#
# Exits 0 on every path. A hook that fails is a hook that interferes with the
# session it is meant to be observing.

set -u

WAIT_DIR="${CC_WAITING_DIR:-${HOME}/.claude/waiting}"
REVIEW_DIR="${CC_WAITING_REVIEW_DIR:-${HOME}/.claude/waiting-review}"

# The rule itself lives in one file, shared with the backfill. They have to
# agree exactly or a session marked by one and re-examined by the other flips
# state for no reason the log would explain.
RULE="${CC_WAITING_RULE:-${BASH_SOURCE[0]%/*}/waiting-rule.jq}"

command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat)
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

read -r event ntype sid cwd <<<"$(printf '%s' "$payload" | jq -r '
	[ (.hook_event_name // "-"),
	  (.notification_type // "-"),
	  (.session_id // "-"),
	  (.cwd // "-") ] | @tsv' 2>/dev/null)"

# Without a session id there is nothing to key on, and every consumer of these
# files matches by exactly that.
[ -n "${sid:-}" ] && [ "$sid" != "-" ] || exit 0

mkdir -p "$WAIT_DIR" 2>/dev/null || exit 0

case "$event" in
Stop)
	# A payload jq could not read must not silently clear a live pending
	# marker -- that would drop a genuine question on a malformed event. An
	# absent message is a different case and does clear it: a turn that said
	# nothing is asking nothing.
	msg=$(printf '%s' "$payload" | jq -r '.last_assistant_message // ""' 2>/dev/null) || exit 0

	# All four verdicts are computed, para and ask are acted on. The other two
	# are carried purely so the log can answer which rule would have been right.
	verdicts=$(printf '%s' "$msg" | jq -Rs -r -f "$RULE" 2>/dev/null)
	[ -n "$verdicts" ] || exit 0

	IFS=$'\t' read -r strict para tail2 ask text <<<"$verdicts"

	# A finished turn retires any standing marker before this one is judged.
	#
	# permission_prompt and the elicitation types mark immediately, and until
	# now only UserPromptSubmit cleared them -- but approving a permission
	# dialog is not a prompt submission, so the marker outlived the block and
	# sat there until the next time you typed. It stayed invisible while Claude
	# worked, because collect.sh will not downgrade a busy window to waiting,
	# and then surfaced as amber the moment the session went idle. Reaching Stop
	# is proof the block is over: Claude cannot finish a turn it is parked in.
	#
	# This costs nothing for genuinely blocked background agents. Those are read
	# from ~/.claude/jobs/*/state.json, not from here, and that signal outranks
	# busy on its own.
	rm -f "${WAIT_DIR}/${sid}"

	if [ "$para" = "true" ] || [ "$ask" = "true" ]; then
		printf 'question\t%s\n' "$text" >"${WAIT_DIR}/${sid}.pending"
	else
		rm -f "${WAIT_DIR}/${sid}.pending"
	fi

	# Every decision, not just the positive ones: a rule's false negatives are
	# only visible if the turns it stayed quiet on were recorded too.
	if mkdir -p "$REVIEW_DIR" 2>/dev/null; then
		jq -c -n --arg ts "$ts" --arg sid "$sid" --arg cwd "$cwd" \
			--arg strict "$strict" --arg para "$para" --arg tail2 "$tail2" \
			--arg ask "$ask" --arg text "$text" \
			'{ts:$ts, session_id:$sid, cwd:$cwd,
			  strict:($strict=="true"), para:($para=="true"),
			  tail2:($tail2=="true"), ask:($ask=="true"), text:$text}' \
			>>"${REVIEW_DIR}/decisions.jsonl" 2>/dev/null
	fi
	;;

Notification)
	case "$ntype" in
	idle_prompt)
		# Promote, never create. idle_prompt fires for every session left
		# alone for 60s, so on its own it means "idle", not "waiting" -- the
		# pending marker is the entire difference between the two.
		if [ -f "${WAIT_DIR}/${sid}.pending" ]; then
			mv -f "${WAIT_DIR}/${sid}.pending" "${WAIT_DIR}/${sid}" 2>/dev/null
		fi
		;;
	permission_prompt | agent_needs_input | elicitation_dialog)
		printf '%s\t%s\n' "$ntype" \
			"$(printf '%s' "$payload" | jq -r '.message // ""' 2>/dev/null)" \
			>"${WAIT_DIR}/${sid}"
		;;
	esac
	;;

# The user typing is a better signal that nothing is waiting on them than any
# notification could be, because it is the event itself rather than a report of
# one. SessionEnd covers the session that exits without ever being answered.
UserPromptSubmit | SessionEnd)
	rm -f "${WAIT_DIR}/${sid}" "${WAIT_DIR}/${sid}.pending"
	;;
esac

exit 0
