#!/usr/bin/env bash
# Report a wrong waiting-status call, and tally the ones already reported.
#
#   waiting-report.sh          pick a turn from the log and say what was wrong
#   waiting-report.sh --tally  summarise what has been reported so far
#
# The status bar decides a session is waiting on you by asking whether the last
# paragraph Claude wrote contains a question mark. That is a guess, and the only
# honest way to find out how good a guess it is was to ship it and measure. So
# claude-waiting.sh logs every turn it judged, along with what the stricter rule
# (does the message END in a question mark) would have said, and this is where
# the two get scored against what actually happened.
#
# Rows are shown whether or not they fired -- a rule's false negatives live
# entirely among the turns it stayed quiet on, and a log of only its positives
# could never surface them.

set -u

REVIEW_DIR="${CC_WAITING_REVIEW_DIR:-${HOME}/.claude/waiting-review}"
DECISIONS="${REVIEW_DIR}/decisions.jsonl"
FEEDBACK="${REVIEW_DIR}/feedback.jsonl"
LIMIT="${CC_WAITING_REPORT_LIMIT:-200}"

# Same palette as the pickers, for the same reason: colour means "this one
# needed you". Degrades to unstyled rather than failing to open.
CC_HELPER="${BASH_SOURCE[0]%/*}/claude-status.sh"
if [[ -r "$CC_HELPER" ]]; then
	# shellcheck source=claude-status.sh
	source "$CC_HELPER"
else
	CC_C_WAIT="" CC_C_DIM="" CC_C_LIVE="" CC_C_OFF=""
fi

if [[ ! -s "$DECISIONS" ]]; then
	echo "No decisions logged yet at ${DECISIONS}."
	echo "The hook writes one per assistant turn; give it a turn or two."
	exit 0
fi

if [[ "${1:-}" == "--tally" ]]; then
	jq -s -r --slurpfile fb <(cat "$FEEDBACK" 2>/dev/null) '
		def pct($n; $d): if $d == 0 then " n/a" else "\(($n * 100 / $d) | round)%" end;
		def fired($k): map(select(.[$k])) | length;

		. as $all
		| ($fb // []) as $f

		# A reported turn carries what should have happened: false_negative
		# means it should have been waiting, false_positive means it should
		# not. Any rule whose verdict differs from that got this turn wrong --
		# which scores all three against the same evidence, including the two
		# that were only ever logged.
		| def missed($k): $f | map(select(.[$k] != (.verdict == "false_negative"))) | length;

		  "turns judged:       \($all | length)",
		  "",
		  "  rule      fired    wrong",
		  "  strict    \($all | fired("strict") | tostring | (" " * (5 - length)) + .)  \(pct($all | fired("strict"); $all | length))    \(missed("strict"))",
		  "  para *    \($all | fired("para")   | tostring | (" " * (5 - length)) + .)  \(pct($all | fired("para");   $all | length))    \(missed("para"))",
		  "  tail2     \($all | fired("tail2")  | tostring | (" " * (5 - length)) + .)  \(pct($all | fired("tail2");  $all | length))    \(missed("tail2"))",
		  "",
		  "  * the live rule. wrong is counted only over the \($f | length) turn(s) you reported,",
		  "    so it is a comparison between rules, not an error rate.",
		  "",
		  "reported wrong:     \($f | length)",
		  "  false positives:  \($f | map(select(.verdict == "false_positive")) | length)   (marked waiting, was not)",
		  "  false negatives:  \($f | map(select(.verdict == "false_negative")) | length)   (left idle, was waiting)"
	' "$DECISIONS"
	exit 0
fi

# Newest first: a wrong call is almost always the one just seen.
recent=$(tail -n "$LIMIT" "$DECISIONS" | { tail -r 2>/dev/null || tac; })

selected=$(
	printf '%s\n' "$recent" | jq -r --arg wait "$CC_C_WAIT" --arg dim "$CC_C_DIM" \
		--arg live "$CC_C_LIVE" --arg off "$CC_C_OFF" '
		# A row where the two rules disagree is the one worth a human glance, so
		# it is marked -- those are exactly the turns that decide the question.
		(if .para then $wait else $dim end) as $c
		| (if .para != .strict then "~" else " " end) as $split
		| (if .para then "waiting" else "  idle " end) as $verdict
		| ((.cwd // "") | split("/") | last // "-") as $where
		| ((.ts | fromdateiso8601 | strflocaltime("%m-%d %H:%M")) // .ts) as $when
		| "\($c)\($when) \($verdict)\($split)\($off) \($live)\($where)\($off) \($c)\(.text[0:110])\($off)\t\(tojson)"
	' 2>/dev/null |
		fzf --ansi --delimiter='\t' --with-nth=1 --accept-nth=2 \
			--ghost="the turn that was judged wrong" \
			--prompt="wrong call> "
)

[[ -z "$selected" ]] && exit 0

was_waiting=$(printf '%s' "$selected" | jq -r 'if .para then "true" else "false" end')

# Offer only the correction that makes sense for what was decided. Presenting
# both would invite recording "false positive" against a turn that never fired.
if [[ "$was_waiting" == "true" ]]; then
	choice="false_positive"
	label="marked waiting, but was NOT waiting on me"
else
	choice="false_negative"
	label="left idle, but WAS waiting on me"
fi

printf '\n  %s\n\n' "$label"
read -rp "  note (optional, enter to skip)> " note

mkdir -p "$REVIEW_DIR"
printf '%s' "$selected" |
	jq -c --arg v "$choice" --arg note "$note" \
		--arg rt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		'. + {verdict: $v, note: $note, reported_at: $rt}' >>"$FEEDBACK"

printf '\n  recorded: %s\n  tally with: waiting-report.sh --tally\n' "$choice"
