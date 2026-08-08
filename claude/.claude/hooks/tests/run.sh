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

printf 'the ask rule\n'

# The turn this rule exists for, reduced to its shape: a request to reply,
# followed by a closing note, and not a question mark anywhere. Every
# punctuation rule misses it, including tail2 -- neither of the last two
# paragraphs has one -- and so would a last-paragraph-only ask.
reset
stop 'Three files staged. Here is the proposed commit message:

```
GH #5126: Only update CSV columns present in the location import file
```

Reply "ok" to commit it, or tell me what to change.

One note on the footer: I put a real customer impact rather than `None`.'
assert_file "$P" "a request to reply pends with no question mark present"
assert_eq "$(jq -r '[.strict, .para, .tail2, .ask] | @tsv' "${CC_WAITING_REVIEW_DIR}/decisions.jsonl")" \
	"$(printf 'false\tfalse\tfalse\ttrue')" "no punctuation rule sees it, ask alone does"

# The row shows the request, not whatever came last. An ask makes its request
# and then keeps explaining, so the first one is the real one -- the opposite of
# how a question behaves.
assert_eq "$(cut -f2- <"$P")" 'Reply "ok" to commit it, or tell me what to change.' \
	"the displayed text is the request, not the closing note"

reset
stop "I fixed it three ways. Why? The index was stale.

So: should I keep all three, or drop the last?"
assert_eq "$(cut -f2- <"$P")" "So: should I keep all three, or drop the last?" \
	"a question still displays the last one, not the first"

for phrase in 'Reply "ok" to commit it.' \
	"Reply with ok and I will push it." \
	"Say the word and I will open the PR."; do
	reset
	stop "$phrase"
	assert_file "$P" "\"${phrase:0:24}...\" pends"
done

# Narrow on purpose. These end a great many turns that have simply finished, and
# a rule that fired on them would leave the bar permanently amber.
for phrase in "Let me know if you want anything else." \
	"I have replied to the review comments." \
	"All three tests pass now."; do
	reset
	stop "$phrase"
	assert_no_file "$P" "\"${phrase:0:24}...\" does not pend"
done

# The one shape known to fire wrongly, pinned so it is a decision rather than a
# surprise. `reply with` has to match mid-sentence to catch "please reply with
# ok", which also catches this. Report it through waiting-report.sh if it turns
# out to happen; the log is what settles whether the trade was worth it.
reset
stop "The parser choked on the reply with the malformed timestamp."
assert_file "$P" "a noun-phrase \"reply with\" fires too -- accepted false positive"

# An ask buried mid-message is an aside, not the close of a turn. This is the
# real shape that made the rule windowed: an optional offer four paragraphs from
# the end of a completion report, followed by results and a handover list.
reset
stop "I chased the two failures across both suites.

If you want certainty I can loop the full suite twenty times. Say the word.

Full suite: 2600 passed, 2 failed, both already red on main.

Working tree clean, one commit on upstream/main.

Still yours to do, unchanged:

1. Create the index before deploy
2. File the two issues
3. Whether to open the PR"
assert_no_file "$P" "an ask four paragraphs from the end does not pend"
assert_eq "$(jq -r '.ask' "${CC_WAITING_REVIEW_DIR}/decisions.jsonl")" "false" \
	"and is logged as not asking, not merely unacted on"

# One paragraph closer and it counts. The boundary is worth pinning because it
# is the whole of the difference between the two turns this rule was tuned on.
reset
stop "Full suite: 2600 passed, 2 failed, both already red on main.

If you want certainty I can loop it twenty times. Say the word.

That is everything else done."
assert_file "$P" "an ask in the second-to-last paragraph does pend"

printf 'the displayed text\n'

# The row gets the sentence that asked, not the paragraph around it. A request
# at the end of a long piece of analysis is the common case, and quoting the
# analysis instead of the request is what makes a row unreadable.
reset
stop "That's strong but not proof. I said I'd tell you plainly which it is, so I believe it is pre-existing interference, and I have not proven it. If you want certainty I can loop the full suite. Say the word."
assert_eq "$(cut -f2- <"$P")" "Say the word." \
	"a long paragraph is trimmed to the asking sentence"

reset
stop "I fixed it three ways. Why? The index was stale. Should I keep all three, or drop the last?"
assert_eq "$(cut -f2- <"$P")" "Should I keep all three, or drop the last?" \
	"a paragraph with two question marks is trimmed to the last one"

# Nothing to trim to: a paragraph that is one sentence must survive whole rather
# than being clipped by a splitter that found no boundary.
reset
stop "Which of these should I use?"
assert_eq "$(cut -f2- <"$P")" "Which of these should I use?" \
	"a single-sentence paragraph is unchanged"

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

printf 'backfill\n'

BACKFILL="$(cd .. && pwd)/claude-waiting-backfill.sh"
export CC_SESSIONS_DIR="${WORK}/sessions"
export CC_PROJECTS_DIR="${WORK}/projects"
# Fixtures are written milliseconds before they are read, so the real 60s idle
# threshold would skip every one of them -- and every negative assertion below
# would then pass for the wrong reason. Zero here so the tests exercise the
# judgement rather than the clock; the threshold gets a test of its own.
export CC_BACKFILL_IDLE_AFTER=0

# A session as the CLI writes it, plus the transcript it would have left behind.
# The transcript is what the backfill reads in place of Stop's payload, so the
# fixture has to carry the same shape: assistant lines, mixed content blocks,
# and the sidechain flag that separates subagent turns from the main thread.
fixture() {
	local pid="$1" status="$2" sid="$3" text="$4" sidechain="${5:-false}"
	mkdir -p "$CC_SESSIONS_DIR" "${CC_PROJECTS_DIR}/proj"
	jq -n --arg s "$status" --arg sid "$sid" --argjson p "$pid" \
		'{pid:$p, status:$s, kind:"interactive", sessionId:$sid, waitingFor:null}' \
		>"${CC_SESSIONS_DIR}/${pid}.json"
	{
		jq -c -n '{type:"user", isSidechain:false, message:{role:"user"}}'
		jq -c -n --arg t "$text" --argjson sc "$sidechain" \
			'{type:"assistant", isSidechain:$sc,
			  message:{content:[{type:"thinking",thinking:"..."},{type:"text",text:$t}]}}'
	} >"${CC_PROJECTS_DIR}/proj/${sid}.jsonl"
}

reset_bf() {
	rm -rf "${WORK:?}/waiting" "${WORK:?}/review" "${WORK:?}/sessions" "${WORK:?}/projects"
}

reset_bf
fixture 1001 idle sid-q "I found three options.

Which should I use?"
out=$("$BACKFILL" 2>&1)
assert_file "${CC_WAITING_DIR}/sid-q" "an idle session with a question is backfilled"
assert_eq "$(cut -f2- <"${CC_WAITING_DIR}/sid-q")" "Which should I use?" \
	"the backfilled marker carries the question"

# A backfilled call is logged like a live one, so it can be reported wrong
# through waiting-report.sh and the rule comparison stays honest.
assert_eq "$(jq -r '.backfill' "${CC_WAITING_REVIEW_DIR}/decisions.jsonl")" "true" \
	"a backfilled decision is logged and flagged"

reset_bf
fixture 1002 idle sid-plain "All three tests pass now."
"$BACKFILL" >/dev/null 2>&1
assert_no_file "${CC_WAITING_DIR}/sid-plain" "an idle session with no question is not backfilled"

# busy means Claude is working. Whatever it asked before, it is not parked on
# the answer now.
reset_bf
fixture 1003 busy sid-busy "Which should I use?"
"$BACKFILL" >/dev/null 2>&1
assert_no_file "${CC_WAITING_DIR}/sid-busy" "a busy session is not backfilled"

# The live path owns anything already in flight. A marker cleared by answering
# must not be resurrected, and a pending one is mid-promotion.
reset_bf
fixture 1004 idle sid-live "Which should I use?"
mkdir -p "$CC_WAITING_DIR"
printf 'permission_prompt\toriginal\n' >"${CC_WAITING_DIR}/sid-live"
"$BACKFILL" >/dev/null 2>&1
assert_eq "$(cut -f2- <"${CC_WAITING_DIR}/sid-live")" "original" \
	"an existing marker is left untouched"

reset_bf
fixture 1005 idle sid-pend "Which should I use?"
mkdir -p "$CC_WAITING_DIR"
printf 'question\tpending\n' >"${CC_WAITING_DIR}/sid-pend.pending"
"$BACKFILL" >/dev/null 2>&1
assert_no_file "${CC_WAITING_DIR}/sid-pend" "a session mid-promotion is not backfilled"

# The live path waits 60s before believing nobody answered. So does this one,
# or a question asked two seconds ago would go amber instantly.
reset_bf
fixture 1006 idle sid-fresh "Which should I use?"
CC_BACKFILL_IDLE_AFTER=99999 "$BACKFILL" >/dev/null 2>&1
assert_no_file "${CC_WAITING_DIR}/sid-fresh" "a session active too recently is not backfilled"

# A subagent's question is answered by the agent that spawned it, not the user.
reset_bf
fixture 1007 idle sid-side "Which should I use?" true
"$BACKFILL" >/dev/null 2>&1
assert_no_file "${CC_WAITING_DIR}/sid-side" "a sidechain question does not mark the window"

reset_bf
fixture 1008 idle sid-notrans "Which should I use?"
rm -rf "${CC_PROJECTS_DIR:?}"
out=$("$BACKFILL" 2>&1)
assert_no_file "${CC_WAITING_DIR}/sid-notrans" "a session with no transcript is not backfilled"
assert_eq "$(printf '%s' "$out" | grep -c '1 unreadable')" "1" \
	"a session with no transcript is counted unreadable"

reset_bf
fixture 1009 idle sid-dry "Which should I use?"
"$BACKFILL" --dry-run >/dev/null 2>&1
assert_no_file "${CC_WAITING_DIR}/sid-dry" "--dry-run writes no marker"
assert_no_file "${CC_WAITING_REVIEW_DIR}/decisions.jsonl" "--dry-run writes no decision"

# Running it twice must not undo an answer given between the two runs.
reset_bf
fixture 1010 idle sid-twice "Which should I use?"
"$BACKFILL" >/dev/null 2>&1
rm -f "${CC_WAITING_DIR}/sid-twice"
"$BACKFILL" >/dev/null 2>&1
assert_file "${CC_WAITING_DIR}/sid-twice" "a re-run re-marks a session whose marker was removed"

reset_bf

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
