#!/usr/bin/env bash
# Tests for srcsync-hook.sh, against a fake srcsync.sh that records its
# arguments and sleeps 5s, so detachment is measured rather than assumed.
#
#   ./srcsync-hook.test.sh

set -u

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
HOOK="$(cd .. && pwd)/srcsync-hook.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

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
	if [ "$1" = "$2" ]; then pass "$3"; else
		fail "$3" "expected: [$1]" "got:      [$2]"
	fi
}

RECORD="${WORK}/record"
FAKE="${WORK}/fake-srcsync.sh"
cat >"$FAKE" <<'EOF'
#!/bin/bash
echo "$0 $*" >>"$RECORD_FILE"
sleep 5
EOF
chmod +x "$FAKE"

export RECORD_FILE="$RECORD"
export SRCSYNC_BIN="$FAKE"

reset() { rm -f "$RECORD"; }

# The hook backgrounds the call, so the record lands some small, unpredictable
# time after the hook itself has already returned. Poll instead of sleeping a
# fixed amount.
poll_record() {
	local n=0
	while [ ! -s "$RECORD" ] && [ "$n" -lt 20 ]; do
		sleep 0.1
		n=$((n + 1))
	done
}

reset
printf '%s' '{"hook_event_name":"Stop","cwd":"/x/y","session_id":"s"}' | "$HOOK"
poll_record
assert_eq "$FAKE auto stop /x/y" "$(cat "$RECORD" 2>/dev/null)" "Stop calls auto stop"

reset
start=$(date +%s)
printf '%s' '{"hook_event_name":"Stop","cwd":"/x/y","session_id":"s"}' | "$HOOK"
end=$(date +%s)
elapsed=$((end - start))
if [ "$elapsed" -le 1 ]; then
	pass "returns at once despite the fake's sleep 5"
else
	fail "returns at once despite the fake's sleep 5" "elapsed: ${elapsed}s"
fi

reset
printf '%s' '{"hook_event_name":"SessionEnd","cwd":"/x/y","session_id":"s"}' | "$HOOK"
poll_record
assert_eq "$FAKE auto end /x/y" "$(cat "$RECORD" 2>/dev/null)" "SessionEnd calls auto end"

reset
printf '%s' '{"hook_event_name":"UserPromptSubmit","cwd":"/x/y","session_id":"s"}' | "$HOOK"
sleep 0.3
assert_eq "" "$(cat "$RECORD" 2>/dev/null)" "an event that is not Stop or SessionEnd records nothing"

reset
SRCSYNC_BIN="${WORK}/nothing-here" "$HOOK" <<<'{"hook_event_name":"Stop","cwd":"/x/y","session_id":"s"}'
rc=$?
assert_eq "0" "$rc" "a missing SRCSYNC_BIN exits 0"

reset
printf 'not json' | "$HOOK"
rc=$?
assert_eq "0" "$rc" "bad JSON exits 0"
sleep 0.3
assert_eq "" "$(cat "$RECORD" 2>/dev/null)" "and never calls the fake"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
