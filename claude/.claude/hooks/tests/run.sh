#!/usr/bin/env bash
# Tests for claude-waiting.sh.
#
# Runs entirely against temp directories -- the hook takes both its state and
# its log location from the environment precisely so this can never touch the
# real ~/.claude/waiting.
#
#   ./run.sh

set -u

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
HOOK="$(cd .. && pwd)/claude-waiting.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export CC_WAITING_DIR="${WORK}/waiting"
export CC_WAITING_REVIEW_DIR="${WORK}/review"

PASS=0
FAIL=0

pass() {
	PASS=$((PASS + 1))
	printf '  ok   %s\n' "$1"
}
fail() {
	FAIL=$((FAIL + 1))
	printf '  FAIL %s\n' "$1"
	shift
	local l
	for l in "$@"; do printf '         %s\n' "$l"; done
}
assert_eq() {
	if [ "$1" = "$2" ]; then pass "$3"; else fail "$3" "expected: [$2]" "actual:   [$1]"; fi
}
assert_file() {
	if [ -f "$1" ]; then pass "$2"; else fail "$2" "missing: $1"; fi
}
assert_no_file() {
	if [ -f "$1" ]; then fail "$2" "unexpectedly present: $1"; else pass "$2"; fi
}

reset() { rm -rf "${WORK:?}/waiting" "${WORK:?}/review"; }

# Feed the hook one event. The message is passed through jq so newlines in the
# fixtures below survive into the JSON exactly as Claude would have written them.
stop() {
	jq -n --arg m "$1" '{session_id:"sid1", hook_event_name:"Stop",
	                     cwd:"/tmp/proj", last_assistant_message:$m}' | "$HOOK"
}
notify() {
	jq -n --arg t "$1" '{session_id:"sid1", hook_event_name:"Notification",
	                     notification_type:$t, message:"Claude is waiting for your input"}' | "$HOOK"
}
event() {
	jq -n --arg e "$1" '{session_id:"sid1", hook_event_name:$e}' | "$HOOK"
}

M="${CC_WAITING_DIR}/sid1"
P="${CC_WAITING_DIR}/sid1.pending"

printf 'the question rule\n'

reset
stop "Here are the options I found.

Which of these should I use?"
assert_file "$P" "a question in the last paragraph pends"

reset
stop "All three tests pass now."
assert_no_file "$P" "a plain statement does not pend"

# The live rule's known blind spot, pinned so it cannot change unnoticed: a
# question with a separate closing paragraph after it scores false, because the
# closing line is then the last paragraph. tail2 is logged for exactly this
# shape, and this test is what will show it was worth logging.
reset
stop "Should I use the loose rule or the strict one?

Either way the backup is at settings.json.bak."
assert_no_file "$P" "a question followed by a closing paragraph does not pend"
assert_eq "$(jq -r '[.strict, .para, .tail2] | @tsv' "${CC_WAITING_REVIEW_DIR}/decisions.jsonl")" \
	"$(printf 'false\tfalse\ttrue')" "the blind spot is logged as tail2-only"

# What the live rule does buy over strict: a question with more text after it in
# the same paragraph. This is the whole of the difference between the two.
reset
stop "Should I use the loose rule? I can also leave it strict."
assert_file "$P" "a question mid-paragraph pends"
assert_eq "$(jq -r '[.strict, .para] | @tsv' "${CC_WAITING_REVIEW_DIR}/decisions.jsonl")" \
	"$(printf 'false\ttrue')" "strict alone would have missed a mid-paragraph question"

reset
stop "Which of these should I use, and does the backup path look right?"
assert_eq "$(jq -r '[.strict, .para] | @tsv' "${CC_WAITING_REVIEW_DIR}/decisions.jsonl")" \
	"$(printf 'true\ttrue')" "both rules agree on a message ending in a question"

# A turn that did not fire is logged too. A rule's false negatives live entirely
# among the turns it stayed quiet on.
reset
stop "Done."
assert_eq "$(jq -r '.para' "${CC_WAITING_REVIEW_DIR}/decisions.jsonl")" "false" \
	"a turn that did not fire is still logged"

# A later plain turn must retract an earlier question -- otherwise a session
# stays armed forever on a question it has already moved past.
reset
stop "Which one?"
stop "Never mind, I worked it out."
assert_no_file "$P" "a later plain turn clears an earlier pending"

printf 'promotion\n'

reset
stop "Which one?"
notify idle_prompt
assert_file "$M" "idle_prompt promotes a pending marker"
assert_no_file "$P" "promotion consumes the pending file"

# idle_prompt fires for every session left alone for 60s. Without a pending
# marker it means idle, which is what the bar already shows.
reset
stop "Done."
notify idle_prompt
assert_no_file "$M" "idle_prompt alone does not create a marker"

# Claude actively blocked needs no inference and no 60s wait.
reset
notify permission_prompt
assert_file "$M" "permission_prompt marks immediately, with no pending stage"

reset
notify agent_needs_input
assert_file "$M" "agent_needs_input marks immediately"

reset
notify elicitation_dialog
assert_file "$M" "elicitation_dialog marks immediately"

printf 'clearing\n'

reset
stop "Which one?"
notify idle_prompt
event UserPromptSubmit
assert_no_file "$M" "answering clears the marker"
assert_no_file "$P" "answering clears any pending too"

reset
stop "Which one?"
event SessionEnd
assert_no_file "$P" "session end clears a pending marker"

reset
notify permission_prompt
event SessionEnd
assert_no_file "$M" "session end clears a live marker"

printf 'robustness\n'

# A malformed payload must not clear a live pending marker: dropping a genuine
# question because one event arrived garbled is the worst available outcome.
reset
stop "Which one?"
printf 'not json at all' | "$HOOK"
rc=$?
assert_eq "$rc" "0" "a malformed payload exits 0"
assert_file "$P" "a malformed payload leaves an existing pending marker alone"

# Every consumer matches by session id, so an event without one has nothing to
# key on and must be a no-op rather than an error.
reset
printf '{"hook_event_name":"Stop","last_assistant_message":"Which one?"}' | "$HOOK"
assert_eq "$?" "0" "an event with no session id exits 0"
assert_eq "$(ls -1 "$CC_WAITING_DIR" 2>/dev/null | wc -l | tr -d ' ')" "0" \
	"an event with no session id writes nothing"

# The marker carries the question so the notification can quote it rather than
# saying "waiting on you" for the third time.
reset
stop "Should I ship the loose rule?"
notify idle_prompt
assert_eq "$(cut -f2- <"$M")" "Should I ship the loose rule?" \
	"the marker carries the question text for the notification"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
