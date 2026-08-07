#!/usr/bin/env bash
# Test runner for the Claude sessions segment.
#
# Runs against a throwaway tmux server on its own socket via the PATH shim in
# bin/, so it is safe to run while the real status bar is live.
#
#   ./run.sh

set -u

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
# shellcheck source=lib.sh
source ./lib.sh

WORK="$(mktemp -d)"
trap 'test_tmux_stop; rm -rf "$WORK"' EXIT

test_tmux_start

SESSIONS="${WORK}/sessions"
mkdir -p "$SESSIONS"

export TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_DIR="$SESSIONS"
export TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_AGENTS_CMD="${CC_TESTS_DIR}/bin/fake-claude"
export CC_FAKE_CLAUDE_LOG="${WORK}/claude.log"
export CC_FAKE_CLAUDE_JSON='[]'

printf 'sourcing\n'
# Not `out="$(cc_load)"`: command substitution forks a subshell, and the
# functions `source` defines there (__cc_collect included) would vanish the
# instant it exits. Redirect stdout to a file instead so sourcing happens in
# this shell and every later direct call to a segment function still works.
cc_load >"${WORK}/source.out"
out="$(cat "${WORK}/source.out")"
assert_eq "$out" "" "sourcing the segment writes nothing to stdout"

printf 'collect\n'

# One idle interactive session, attributed to the window that owns it.
pid_w1="$(test_window_pid w1:0)"
session_file "$SESSIONS" "$pid_w1" idle interactive
raw="$(__cc_collect "$SESSIONS" "")"
assert_contains "$raw" "COUNTS 0 0 1" "one idle session counts as idle"
assert_contains "$raw" "WIN w1:0 idle" "idle session attributed to its window"

# Most demanding state wins when two sessions share one window. This needs
# two real panes: __cc_collect attributes a session by walking its pid (via
# the parent[] map built from real `ps` output) up to an entry in the pane[]
# map built from real `tmux list-panes` output. A fabricated pid that was
# never an actual process has no parent[] entry, so the walk breaks
# immediately and such a fixture never attributes to any window -- it would
# only inflate the global counters, never exercise the rank comparison.
tmux split-window -t w1:0
pids_w1=()
while IFS= read -r p; do pids_w1+=("$p"); done < <(tmux list-panes -t w1:0 -F '#{pane_pid}')
pid_a="${pids_w1[0]}"
pid_b="${pids_w1[1]}"

rm -f "$SESSIONS"/*.json
session_file "$SESSIONS" "$pid_a" idle interactive
session_file "$SESSIONS" "$pid_b" busy interactive
raw="$(__cc_collect "$SESSIONS" "")"
assert_contains "$raw" "COUNTS 0 1 1" "busy and idle counted separately"
assert_contains "$raw" "WIN w1:0 busy" "busy outranks idle in the same window"

rm -f "$SESSIONS"/*.json
session_file "$SESSIONS" "$pid_a" waiting interactive
session_file "$SESSIONS" "$pid_b" busy interactive
raw="$(__cc_collect "$SESSIONS" "")"
assert_contains "$raw" "WIN w1:0 waiting" "waiting outranks busy in the same window"

printf 'empty\n'
rm -f "$SESSIONS"/*.json
raw="$(__cc_collect "$SESSIONS" "")"
assert_eq "$raw" "EMPTY" "an empty sessions directory yields EMPTY"

printf 'collect: pid and ambiguous set\n'
rm -f "$SESSIONS"/*.json

# The WIN line carries the pid of the session that won the window, so a
# notification can look up waitingFor lazily instead of threading it through awk.
session_file "$SESSIONS" "$pid_w1" waiting interactive
raw="$(__cc_collect "$SESSIONS" "")"
assert_contains "$raw" "WIN w1:0 waiting ${pid_w1}" "WIN line carries the winning session pid"

# A background session sitting at idle is ambiguous: the file cannot say whether
# it is blocked on input, so only this state warrants asking the binary.
rm -f "$SESSIONS"/*.json
session_file "$SESSIONS" 900001 idle bg
raw="$(__cc_collect "$SESSIONS" "")"
assert_contains "$raw" "AMB 900001" "an idle bg session is ambiguous"

# Busy and waiting are conclusive from the file alone.
rm -f "$SESSIONS"/*.json
session_file "$SESSIONS" 900002 busy bg
raw="$(__cc_collect "$SESSIONS" "")"
assert_not_contains "$raw" "AMB" "a busy bg session is not ambiguous"

rm -f "$SESSIONS"/*.json
session_file "$SESSIONS" 900003 waiting bg
raw="$(__cc_collect "$SESSIONS" "")"
assert_not_contains "$raw" "AMB" "a waiting bg session is not ambiguous"

# Interactive sessions never warrant the binary.
rm -f "$SESSIONS"/*.json
session_file "$SESSIONS" "$pid_w1" idle interactive
raw="$(__cc_collect "$SESSIONS" "")"
assert_not_contains "$raw" "AMB" "an idle interactive session is not ambiguous"

# The ambiguous set is built from the RAW file status. A bg session promoted to
# waiting by the blocked list is still ambiguous, or the set would flip every
# time the promotion took effect and re-trigger the binary forever.
rm -f "$SESSIONS"/*.json
session_file "$SESSIONS" 900004 idle bg
printf '900004\n' >"${WORK}/blocked.list"
raw="$(__cc_collect "$SESSIONS" "${WORK}/blocked.list")"
assert_contains "$raw" "AMB 900004" "a promoted bg session stays in the ambiguous set"
assert_contains "$raw" "COUNTS 1 0 0" "a promoted bg session counts as waiting"
rm -f "${WORK}/blocked.list"

printf 'torn reads\n'
rm -f "$SESSIONS"/*.json

# A file caught mid-write aborts jq, which yields no records at all. That must
# not be reported as an empty directory: the caller responds to EMPTY by
# stripping every window option, which would make the following tick read every
# waiting window as a brand new transition.
printf '{"pid":900010,"status":"idl' >"${SESSIONS}/900010.json"
raw="$(__cc_collect "$SESSIONS" "")"
assert_eq "$raw" "TORN" "a truncated session file yields TORN"

# jq parses the concatenated stream, so one bad file poisons the whole read.
# Assert that rather than assume it.
session_file "$SESSIONS" 900011 idle interactive
raw="$(__cc_collect "$SESSIONS" "")"
assert_eq "$raw" "TORN" "one truncated file among valid ones still yields TORN"

# A genuinely empty directory is still EMPTY. The count-trimming design depends
# on that meaning being unchanged.
rm -f "$SESSIONS"/*.json
raw="$(__cc_collect "$SESSIONS" "")"
assert_eq "$raw" "EMPTY" "an empty directory is still EMPTY, not TORN"

printf 'agent refresh triggering\n'
BLOCKED="${WORK}/blocked.list"

# Each case starts from a clean cache and a clean invocation log.
refresh_case() {
	rm -f "$BLOCKED" "$CC_FAKE_CLAUDE_LOG"
	tmux set-option -gu @cc_bg_amb 2>/dev/null
	__cc_refresh_blocked "$BLOCKED" "$1"
	# The refresh is deliberately detached so it can never stall the status
	# bar. It is a direct child of this shell, so wait for it here rather than
	# spinning on the files it writes.
	wait 2>/dev/null
}

calls() { [ -f "$CC_FAKE_CLAUDE_LOG" ] && wc -l <"$CC_FAKE_CLAUDE_LOG" | tr -d ' ' || echo 0; }

# An empty ambiguous set must never spawn the binary. This is the steady state
# on a machine with no idle background agents, and it should cost nothing.
refresh_case ""
assert_eq "$(calls)" "0" "an empty ambiguous set never invokes the binary"

# A non-empty set with no stored fingerprint is a first look: ask.
refresh_case "900001"
assert_eq "$(calls)" "1" "a new ambiguous set invokes the binary once"

# The same set, already answered, must not ask again.
rm -f "$CC_FAKE_CLAUDE_LOG"
__cc_refresh_blocked "$BLOCKED" "900001"
assert_eq "$(calls)" "0" "an unchanged ambiguous set does not re-invoke"

# A changed set must ask again. Same detached-child reasoning as refresh_case:
# wait for it here so the check below lands after the binary actually runs,
# rather than racing tmux/jq startup latency.
rm -f "$CC_FAKE_CLAUDE_LOG"
__cc_refresh_blocked "$BLOCKED" "900001 900002"
wait 2>/dev/null
assert_eq "$(calls)" "1" "a changed ambiguous set invokes the binary"

# Emptying the set clears the cache without asking: a bg session that is not
# idle cannot be blocked, so there is nothing to disambiguate.
rm -f "$CC_FAKE_CLAUDE_LOG"
__cc_refresh_blocked "$BLOCKED" ""
assert_eq "$(calls)" "0" "emptying the ambiguous set does not invoke the binary"
assert_eq "$(cat "$BLOCKED" 2>/dev/null)" "" "emptying the ambiguous set clears the blocked list"

# Only agents carrying a pid are usable. The others are parked conversations
# with no process, which cannot be attributed to a window.
export CC_FAKE_CLAUDE_JSON='[{"kind":"background","state":"blocked","name":"no-pid"},{"kind":"background","state":"blocked","pid":900007,"name":"has-pid"}]'
refresh_case "900007"
assert_eq "$(cat "$BLOCKED" 2>/dev/null)" "900007" "only blocked agents with a pid reach the list"
export CC_FAKE_CLAUDE_JSON='[]'

printf 'transition detection\n'

# Each case rebuilds window state from scratch.
sync_case() {
	local -A d=()
	local w
	for w in $1; do d["${w%%=*}"]="${w##*=}"; done
	CC_TRANS=()
	__cc_sync_windows d CC_TRANS
}

tmux set-option -gu @cc_primed 2>/dev/null
tmux list-windows -a -F '#{session_name}:#{window_index}' | while read -r w; do
	tmux set-option -w -t "$w" -u @cc_state 2>/dev/null
done

# First run after a server start has no @cc_state anywhere, so every waiting
# session would read as a fresh transition. Priming must swallow that burst.
sync_case "w1:0=waiting w1:1=waiting"
assert_eq "${#CC_TRANS[@]}" "0" "the first sync primes state and notifies nothing"

# With state primed, a genuine transition is reported.
sync_case "w1:0=idle w1:1=idle"
sync_case "w1:0=waiting w1:1=idle"
assert_eq "${CC_TRANS[*]}" "w1:0" "entering waiting is reported once"

# Holding at waiting is not a transition.
sync_case "w1:0=waiting w1:1=idle"
assert_eq "${#CC_TRANS[@]}" "0" "staying in waiting reports nothing"

# Leaving and re-entering is a new transition.
sync_case "w1:0=busy w1:1=idle"
sync_case "w1:0=waiting w1:1=idle"
assert_eq "${CC_TRANS[*]}" "w1:0" "re-entering waiting is reported again"

# A transition that straddles a skipped sync is delayed, not lost: the previous
# state lives in the window option, so the next sync still sees the edge.
sync_case "w1:0=idle w1:1=idle"
# (no sync at all here, standing in for a torn tick)
sync_case "w1:0=waiting w1:1=idle"
assert_eq "${CC_TRANS[*]}" "w1:0" "a transition across a skipped tick still reports"

printf 'focus suppression\n'
# The window the user is looking at needs no notification: the amber bubble is
# already on screen.
#
# This needs a genuinely attached client. A detached server reports
# session_attached 0 for everything, which would make every window look
# unfocused and leave the suppression path silently untested. script(1) gives
# the client a pty without this test needing a terminal of its own.
#
# A fresh session of its own, and the client attaches before the second
# window even exists. A window that is current when the first client ever
# attaches to its session survives; a window that has been sitting current
# and unattended for a while does not -- the pane behind it gets torn down
# by the time the client registers. Attaching first, and only creating the
# second window afterwards, keeps every window's pane alive for the rest of
# the case.
tmux new-session -d -s w2
script -q /dev/null tmux attach -t w2 >/dev/null 2>&1 &
CC_CLIENT_PID=$!
i=0
while [ $i -lt 100 ]; do
	[ -n "$(tmux list-clients -F '#{client_name}' 2>/dev/null)" ] && break
	i=$((i + 1))
	sleep 0.05
done
assert_contains "$(tmux list-windows -t w2 -F '#{session_attached}')" "1" "the test client attached"

tmux new-window -t w2
tmux select-window -t w2:0
sync_case "w2:0=idle w2:1=idle"

# Both windows enter waiting together. Only the unfocused one is reported,
# which asserts suppression and non-suppression in a single comparison.
sync_case "w2:0=waiting w2:1=waiting"
assert_eq "${CC_TRANS[*]}" "w2:1" "the focused window is suppressed, the unfocused one is not"

kill "$CC_CLIENT_PID" 2>/dev/null

printf 'notification delivery\n'
export TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_NOTIFY_CMD="${CC_TESTS_DIR}/bin/fake-notify"
export CC_NOTIFY_LOG="${WORK}/notify.log"

notify_case() {
	rm -f "$CC_NOTIFY_LOG"
	local -a t=($1)
	local -A p=()
	local kv
	for kv in ${2:-}; do p["${kv%%=*}"]="${kv##*=}"; done
	__cc_notify "$SESSIONS" t p
}

rm -f "$SESSIONS"/*.json

# No transitions, no notification, no process spawned.
notify_case "" ""
assert_eq "$(cat "$CC_NOTIFY_LOG" 2>/dev/null)" "" "no transitions delivers nothing"

# The window is the headline. waitingFor is looked up from the session file of
# the pid that won the window, and only when a notification actually fires.
session_file "$SESSIONS" 900020 waiting interactive "" "" "permission prompt"
notify_case "w1:0" "w1:0=900020"
assert_eq "$(cat "$CC_NOTIFY_LOG" 2>/dev/null)" "$(printf 'w1:0\tpermission prompt')" "the window and waitingFor are delivered"

# waitingFor is frequently null. The notification must still fire.
rm -f "$SESSIONS"/*.json
session_file "$SESSIONS" 900021 waiting interactive
notify_case "w1:0" "w1:0=900021"
assert_contains "$(cat "$CC_NOTIFY_LOG" 2>/dev/null)" "w1:0" "a missing waitingFor still notifies"

# Several windows going waiting at once each get their own notification.
rm -f "$SESSIONS"/*.json
session_file "$SESSIONS" 900022 waiting interactive
session_file "$SESSIONS" 900023 waiting interactive
notify_case "w1:0 w1:1" "w1:0=900022 w1:1=900023"
assert_eq "$(wc -l <"$CC_NOTIFY_LOG" | tr -d ' ')" "2" "two transitions deliver two notifications"

printf '\n%d passed, %d failed\n' "$CC_PASS" "$CC_FAIL"
[ "$CC_FAIL" -eq 0 ]
