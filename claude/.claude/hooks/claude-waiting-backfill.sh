#!/usr/bin/env bash
# Mark sessions that were already sitting on a question before the hook existed.
#
# claude-waiting.sh only ever sees turns that END after it is installed, and a
# session parked on an unanswered question produces no further turns -- that is
# what being parked means. So every session already stuck at the moment the hook
# went live would stay grey forever, and those are precisely the ones the whole
# feature is for. The same gap reopens after any settings change that drops the
# hook, and on a fresh machine the moment install-hooks.sh runs.
#
# The judgement is identical to the live one; only the source of the text
# differs. Instead of Stop handing over last_assistant_message, the last
# assistant message is read back out of the session transcript.
#
# Safe to run repeatedly. It only ever adds a marker to a session that has none,
# so a marker cleared by answering is not resurrected on the next run.
#
#   ./claude-waiting-backfill.sh [--dry-run]

set -u

WAIT_DIR="${CC_WAITING_DIR:-${HOME}/.claude/waiting}"
REVIEW_DIR="${CC_WAITING_REVIEW_DIR:-${HOME}/.claude/waiting-review}"
SESSIONS_DIR="${CC_SESSIONS_DIR:-${HOME}/.claude/sessions}"
PROJECTS_DIR="${CC_PROJECTS_DIR:-${HOME}/.claude/projects}"

# How long a session must have been quiet before its question counts as
# unanswered. Mirrors the fixed 60s that idle_prompt waits in the live path, so
# a backfilled marker means the same thing as a promoted one.
IDLE_AFTER="${CC_BACKFILL_IDLE_AFTER:-60}"

# Transcripts grow without bound and only the tail can hold the final assistant
# message of a session that has stopped. Bounded so this stays cheap on a
# machine with thirty of them.
TAIL_LINES="${CC_BACKFILL_TAIL_LINES:-400}"

DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

command -v jq >/dev/null 2>&1 || {
	echo "backfill: jq is required" >&2
	exit 1
}

[ -d "$SESSIONS_DIR" ] || exit 0
mkdir -p "$WAIT_DIR" 2>/dev/null || exit 0

now=$(date +%s)
marked=0
skipped=0

for f in "$SESSIONS_DIR"/*.json; do
	[ -f "$f" ] || continue

	IFS=$'\t' read -r status sid < <(
		jq -r '[(.status // ""), (.sessionId // "")] | @tsv' "$f" 2>/dev/null
	)
	[ -n "${sid:-}" ] || continue

	# busy is working, and waiting is already reported by the session file
	# itself. Only idle is the state that hides an unanswered question.
	[ "$status" = "idle" ] || continue

	# Never overwrite live state. A marker cleared by answering must stay
	# cleared, and a pending one belongs to the live path.
	[ -e "${WAIT_DIR}/${sid}" ] || [ -e "${WAIT_DIR}/${sid}.pending" ] && continue

	mtime=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null)
	[ -n "$mtime" ] || continue
	[ "$((now - mtime))" -ge "$IDLE_AFTER" ] || continue

	transcript=$(find "$PROJECTS_DIR" -name "${sid}.jsonl" -type f 2>/dev/null | head -1)
	[ -n "$transcript" ] || {
		skipped=$((skipped + 1))
		continue
	}

	# Sidechains are subagent turns. A subagent's question is answered by the
	# agent that spawned it, not by the user, so it says nothing about whether
	# this window needs attention.
	text=$(tail -n "$TAIL_LINES" "$transcript" 2>/dev/null | jq -r -s '
		[ .[]
		  | select(.type == "assistant" and (.isSidechain | not))
		  | .message.content[]?
		  | select(.type == "text")
		  | .text ]
		| last // ""' 2>/dev/null)

	[ -n "$text" ] || {
		skipped=$((skipped + 1))
		continue
	}

	verdicts=$(printf '%s' "$text" | jq -R -s -r '
		sub("[[:space:]]+$"; "")
		| . as $msg
		| ($msg | split("\n\n")) as $paras
		| ($paras | last // "") as $para
		| ($paras[-2:] | join(" ")) as $tail2
		| [ ($msg   | endswith("?")),
		    ($para  | test("\\?")),
		    ($tail2 | test("\\?")),
		    ($para  | gsub("[[:space:]]+"; " ") | .[0:300]) ]
		| @tsv' 2>/dev/null)
	[ -n "$verdicts" ] || continue

	IFS=$'\t' read -r strict para tail2 para_text <<<"$verdicts"

	# Logged whichever way it goes, exactly as the live path does, so a
	# backfilled call can be reported wrong through waiting-report.sh like any
	# other and the rule comparison stays honest.
	if [ "$DRY" -eq 0 ] && mkdir -p "$REVIEW_DIR" 2>/dev/null; then
		jq -c -n --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg sid "$sid" \
			--arg cwd "$(dirname "$transcript")" --arg strict "$strict" \
			--arg para "$para" --arg tail2 "$tail2" --arg text "$para_text" \
			'{ts:$ts, session_id:$sid, cwd:$cwd,
			  strict:($strict=="true"), para:($para=="true"),
			  tail2:($tail2=="true"), text:$text, backfill:true}' \
			>>"${REVIEW_DIR}/decisions.jsonl" 2>/dev/null
	fi

	if [ "$para" = "true" ]; then
		marked=$((marked + 1))
		printf '  %s  %s\n' "${sid:0:8}" "${para_text:0:90}"
		[ "$DRY" -eq 0 ] &&
			printf 'question\t%s\n' "$para_text" >"${WAIT_DIR}/${sid}"
	fi
done

if [ "$DRY" -eq 1 ]; then
	printf 'backfill --dry-run: %d session(s) would be marked, %d unreadable\n' \
		"$marked" "$skipped"
else
	printf 'backfill: %d session(s) marked, %d unreadable\n' "$marked" "$skipped"
fi
