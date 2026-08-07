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
JOBS="${WORK}/jobs"
MARKS="${WORK}/waiting"
mkdir -p "$SESSIONS" "$JOBS" "$MARKS"

export TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_DIR="$SESSIONS"
# Both must be exported before any run_segment test: left unset the segment
# would fall back to the real ~/.claude/jobs and ~/.claude/waiting, and the
# suite would report on whatever agents happen to be blocked, and whatever
# sessions happen to be waiting, on this machine.
export TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_JOBS_DIR="$JOBS"
export TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_MARKS_DIR="$MARKS"

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
raw="$(__cc_collect "$SESSIONS" "" "$MARKS")"
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
raw="$(__cc_collect "$SESSIONS" "" "$MARKS")"
assert_contains "$raw" "COUNTS 0 1 1" "busy and idle counted separately"
assert_contains "$raw" "WIN w1:0 busy" "busy outranks idle in the same window"

rm -f "$SESSIONS"/*.json
session_file "$SESSIONS" "$pid_a" waiting interactive
session_file "$SESSIONS" "$pid_b" busy interactive
raw="$(__cc_collect "$SESSIONS" "" "$MARKS")"
assert_contains "$raw" "WIN w1:0 waiting" "waiting outranks busy in the same window"

printf 'empty\n'
rm -f "$SESSIONS"/*.json
raw="$(__cc_collect "$SESSIONS" "" "$MARKS")"
assert_eq "$raw" "EMPTY" "an empty sessions directory yields EMPTY"

printf 'collect: pid and ambiguous set\n'
rm -f "$SESSIONS"/*.json

# The WIN line carries the pid of the session that won the window, so a
# notification can look up waitingFor lazily instead of threading it through awk.
session_file "$SESSIONS" "$pid_w1" waiting interactive
raw="$(__cc_collect "$SESSIONS" "" "$MARKS")"
assert_contains "$raw" "WIN w1:0 waiting ${pid_w1}" "WIN line carries the winning session pid"

printf 'collect: blocked background agents\n'

# The case this whole path exists for. A background agent has no pid and no
# session file of its own; the only trace it leaves is a job state directory.
# Its sessionId names the interactive session that owns it, and that session
# does have a pid, which resolves to the window the user is looking at.
rm -f "$SESSIONS"/*.json
rm -rf "${JOBS:?}"/*
session_file "$SESSIONS" "$pid_w1" idle interactive "sid-aaa"
job_file "$JOBS" job1 blocked "sid-aaa"
raw="$(__cc_collect "$SESSIONS" "$JOBS" "$MARKS")"
assert_contains "$raw" "WIN w1:0 waiting" "a blocked agent marks its owning window waiting"
assert_contains "$raw" "COUNTS 1 0 0" "a blocked agent counts as waiting"

# An agent that is not blocked says nothing about its owner.
rm -rf "${JOBS:?}"/*
job_file "$JOBS" job1 running "sid-aaa"
raw="$(__cc_collect "$SESSIONS" "$JOBS" "$MARKS")"
assert_contains "$raw" "WIN w1:0 idle" "a running agent leaves its owner idle"
assert_contains "$raw" "COUNTS 0 0 1" "a running agent does not count as waiting"

# Stale agents are the common case: three of the four blocked jobs on a real
# machine were weeks old, parked against sessions that had long since exited.
# Matching on sessionId drops them for free -- no live session, no window.
rm -rf "${JOBS:?}"/*
job_file "$JOBS" old1 blocked "sid-long-gone"
raw="$(__cc_collect "$SESSIONS" "$JOBS" "$MARKS")"
assert_contains "$raw" "WIN w1:0 idle" "a blocked agent with no live owner marks nothing"
assert_contains "$raw" "COUNTS 0 0 1" "a stale blocked agent does not count as waiting"

# Several agents can be blocked under one session. The window is waiting once.
rm -rf "${JOBS:?}"/*
job_file "$JOBS" job1 blocked "sid-aaa"
job_file "$JOBS" job2 blocked "sid-aaa"
raw="$(__cc_collect "$SESSIONS" "$JOBS" "$MARKS")"
assert_contains "$raw" "WIN w1:0 waiting" "two blocked agents under one session still mark it waiting"

# A blocked agent outranks its owner's own busy state, same as any waiting.
rm -f "$SESSIONS"/*.json
rm -rf "${JOBS:?}"/*
session_file "$SESSIONS" "$pid_w1" busy interactive "sid-aaa"
job_file "$JOBS" job1 blocked "sid-aaa"
raw="$(__cc_collect "$SESSIONS" "$JOBS" "$MARKS")"
assert_contains "$raw" "WIN w1:0 waiting" "a blocked agent outranks its owner's busy state"

# A job directory holding no state.json is a leftover temp dir -- two of the six
# on a real machine were exactly that. It must read as "nothing blocked", not as
# a failed read.
rm -f "$SESSIONS"/*.json
rm -rf "${JOBS:?}"/*
session_file "$SESSIONS" "$pid_w1" idle interactive "sid-aaa"
mkdir -p "${JOBS}/leftover/tmp"
raw="$(__cc_collect "$SESSIONS" "$JOBS" "$MARKS")"
assert_contains "$raw" "COUNTS 0 0 1" "a job dir with no state.json is not blocked"
assert_not_contains "$raw" "TORN" "a job dir with no state.json is not a torn read"

# A jobs directory that does not exist at all is the machine that has never run
# a background agent. Also not a failure.
rm -rf "${JOBS:?}"/*
raw="$(__cc_collect "$SESSIONS" "${WORK}/no-such-jobs-dir" "$MARKS")"
assert_contains "$raw" "COUNTS 0 0 1" "a missing jobs directory is not blocked"
assert_not_contains "$raw" "TORN" "a missing jobs directory is not a torn read"

# But a state.json caught mid-write is a torn read. Guessing "nothing blocked"
# would drop every window out of waiting for a tick and then put them back,
# which is a notification burst on the recovery tick.
mkdir -p "${JOBS}/torn"
printf '{"state":"bloc' >"${JOBS}/torn/state.json"
raw="$(__cc_collect "$SESSIONS" "$JOBS" "$MARKS")"
assert_eq "$raw" "TORN" "a truncated job state file yields TORN"
rm -rf "${JOBS:?}"/*

printf 'collect: hook waiting markers\n'

# The case no file Claude Code writes can express. The session file says idle
# and means it -- Claude really is doing nothing -- but it is doing nothing
# because it asked a question nobody has answered. Only the hook saw the text.
rm -f "$SESSIONS"/*.json
rm -f "${MARKS:?}"/*
session_file "$SESSIONS" "$pid_w1" idle interactive "sid-aaa"
mark_file "$MARKS" "sid-aaa"
raw="$(__cc_collect "$SESSIONS" "" "$MARKS")"
assert_contains "$raw" "WIN w1:0 waiting" "a hook marker marks its session's window waiting"
assert_contains "$raw" "COUNTS 1 0 0" "a marked session counts as waiting"

# A pending marker is not a marker. Claude has asked, but the 60s idle_prompt
# that confirms nobody answered has not fired -- promoting here would light up
# every window the instant a turn ended, which is the whole thing the two-stage
# design exists to avoid.
rm -f "${MARKS:?}"/*
mark_file "$MARKS" "sid-aaa" question "any more?" pending
raw="$(__cc_collect "$SESSIONS" "" "$MARKS")"
assert_contains "$raw" "WIN w1:0 idle" "a pending marker does not mark a window waiting"
assert_contains "$raw" "COUNTS 0 0 1" "a pending marker does not count as waiting"

# Same staleness dividend as blocked agents: a marker whose session has exited
# resolves to no pid and so to no window, with no age heuristic needed.
rm -f "${MARKS:?}"/*
mark_file "$MARKS" "sid-long-gone"
raw="$(__cc_collect "$SESSIONS" "" "$MARKS")"
assert_contains "$raw" "COUNTS 0 0 1" "a marker with no live session marks nothing"

# Busy beats a marker, and only a marker. The marker says Claude asked and was
# not answered as of a minute ago; a session now working is evidence that has
# expired however it got cleared.
rm -f "$SESSIONS"/*.json
rm -f "${MARKS:?}"/*
session_file "$SESSIONS" "$pid_w1" busy interactive "sid-aaa"
mark_file "$MARKS" "sid-aaa"
raw="$(__cc_collect "$SESSIONS" "" "$MARKS")"
assert_contains "$raw" "WIN w1:0 busy" "a busy session outranks a stale hook marker"

# But a blocked agent still outranks busy, because it is parked right now and
# its owner working on something else does not unpark it.
rm -rf "${JOBS:?}"/*
job_file "$JOBS" job1 blocked "sid-aaa"
raw="$(__cc_collect "$SESSIONS" "$JOBS" "$MARKS")"
assert_contains "$raw" "WIN w1:0 waiting" "a blocked agent still outranks busy alongside a marker"
rm -rf "${JOBS:?}"/*

# A marker directory that does not exist is the machine where the hook has
# never fired. Not a failure, and not a reason to blank the bar.
rm -f "$SESSIONS"/*.json
rm -f "${MARKS:?}"/*
session_file "$SESSIONS" "$pid_w1" idle interactive "sid-aaa"
raw="$(__cc_collect "$SESSIONS" "" "${WORK}/no-such-marks-dir")"
assert_contains "$raw" "COUNTS 0 0 1" "a missing marker directory is not waiting"
assert_not_contains "$raw" "TORN" "a missing marker directory is not a torn read"

printf 'torn reads\n'
rm -f "$SESSIONS"/*.json

# A file caught mid-write aborts jq, which yields no records at all. That must
# not be reported as an empty directory: the caller responds to EMPTY by
# stripping every window option, which would make the following tick read every
# waiting window as a brand new transition.
printf '{"pid":900010,"status":"idl' >"${SESSIONS}/900010.json"
raw="$(__cc_collect "$SESSIONS" "" "$MARKS")"
assert_eq "$raw" "TORN" "a truncated session file yields TORN"

# jq parses the concatenated stream, so one bad file poisons the whole read.
# Assert that rather than assume it.
session_file "$SESSIONS" 900011 idle interactive
raw="$(__cc_collect "$SESSIONS" "" "$MARKS")"
assert_eq "$raw" "TORN" "one truncated file among valid ones still yields TORN"

# A genuinely empty directory is still EMPTY. The count-trimming design depends
# on that meaning being unchanged.
rm -f "$SESSIONS"/*.json
raw="$(__cc_collect "$SESSIONS" "" "$MARKS")"
assert_eq "$raw" "EMPTY" "an empty directory is still EMPTY, not TORN"

# A Claude process SIGKILLed mid-write leaves a 0-byte file behind, and nothing
# ever cleans it up -- that is the job of the exiting process. jq reads no input
# from it and exits 0, so this is a clean read of a directory with no sessions.
#
# Deciding TORN by "were there files present" instead froze the segment
# permanently: once every real session had exited, the stray file was the only
# one left, no records parsed, and every tick from then on returned TORN. The
# bar held a stale frame, every window kept a stale @cc_state, and notifications
# stopped -- with nothing on screen to say so.
rm -f "$SESSIONS"/*.json
: >"${SESSIONS}/900012.json"
raw="$(__cc_collect "$SESSIONS" "" "$MARKS")"
assert_eq "$raw" "EMPTY" "a stray 0-byte session file yields EMPTY, not TORN"

# Same reasoning one step along: a well-formed file whose pid or status is null
# parses cleanly and is simply dropped by the select. No records, but no failure
# either.
rm -f "$SESSIONS"/*.json
printf '{"pid":null,"status":null}\n' >"${SESSIONS}/900013.json"
raw="$(__cc_collect "$SESSIONS" "" "$MARKS")"
assert_eq "$raw" "EMPTY" "a session file with null pid and status yields EMPTY"

# The other two inputs need a sentinel of their own. If `ps` or `tmux
# list-panes` comes back empty for a tick, the pid walk resolves nothing and awk
# would print COUNTS with no WIN lines at all -- which the caller reads as "no
# window hosts a session", strips every window option, and so re-reads every
# waiting window as a fresh transition on the next healthy tick. That is a burst
# of up to one notification per waiting window.
rm -f "$SESSIONS"/*.json
session_file "$SESSIONS" "$pid_w1" waiting interactive

STUBS="${WORK}/stubs"
mkdir -p "$STUBS"
printf '#!/bin/sh\nexit 0\n' >"${STUBS}/ps"
printf '#!/bin/sh\nexit 0\n' >"${STUBS}/tmux"
chmod +x "${STUBS}/ps" "${STUBS}/tmux"

saved_path="$PATH"
PATH="${STUBS}:${PATH}"
# Only ps is stubbed here; the tmux shim is still reachable further down PATH.
rm -f "${STUBS}/tmux"
raw="$(__cc_collect "$SESSIONS" "" "$MARKS")"
PATH="$saved_path"
assert_eq "$raw" "TORN" "an empty process table yields TORN, not a windowless COUNTS"

PATH="${STUBS}:${PATH}"
rm -f "${STUBS}/ps"
printf '#!/bin/sh\nexit 0\n' >"${STUBS}/tmux"
chmod +x "${STUBS}/tmux"
raw="$(__cc_collect "$SESSIONS" "" "$MARKS")"
PATH="$saved_path"
assert_eq "$raw" "TORN" "an empty pane list yields TORN, not a windowless COUNTS"
rm -f "${STUBS}/tmux"

# Gating on the inputs, not on the output: zero WIN lines is legitimate when
# every live session is a background agent with no window of its own, and
# calling that TORN would wedge the bar just as badly.
rm -f "$SESSIONS"/*.json
session_file "$SESSIONS" 900014 idle bg
raw="$(__cc_collect "$SESSIONS" "" "$MARKS")"
assert_contains "$raw" "COUNTS 0 0 1" "a windowless bg session still reports counts"
assert_not_contains "$raw" "WIN" "a windowless bg session produces no WIN line"
assert_not_contains "$raw" "TORN" "no WIN lines from a healthy read is not TORN"
rm -f "$SESSIONS"/*.json

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
wait 2>/dev/null
assert_eq "$(cat "$CC_NOTIFY_LOG" 2>/dev/null)" "" "no transitions delivers nothing"

# The window is the headline. waitingFor is looked up from the session file of
# the pid that won the window, and only when a notification actually fires.
session_file "$SESSIONS" 900020 waiting interactive "" "permission prompt"
notify_case "w1:0" "w1:0=900020"
# The delivery itself is detached (never blocks a redraw), so the assertion
# below would otherwise race the fork -- same fix as Task 5's refresh_case.
wait 2>/dev/null
assert_eq "$(cat "$CC_NOTIFY_LOG" 2>/dev/null)" "$(printf 'w1:0\tpermission prompt')" "the window and waitingFor are delivered"

# waitingFor is frequently null. The notification must still fire.
rm -f "$SESSIONS"/*.json
session_file "$SESSIONS" 900021 waiting interactive
notify_case "w1:0" "w1:0=900021"
wait 2>/dev/null
assert_contains "$(cat "$CC_NOTIFY_LOG" 2>/dev/null)" "w1:0" "a missing waitingFor still notifies"

# Several windows going waiting at once each get their own notification.
rm -f "$SESSIONS"/*.json
session_file "$SESSIONS" 900022 waiting interactive
session_file "$SESSIONS" 900023 waiting interactive
notify_case "w1:0 w1:1" "w1:0=900022 w1:1=900023"
wait 2>/dev/null
assert_eq "$(wc -l <"$CC_NOTIFY_LOG" | tr -d ' ')" "2" "two transitions deliver two notifications"

# Every case above goes through NOTIFY_CMD, which never touches the shell
# escaping in the terminal-notifier branch. session names are user-controlled
# and can contain a single quote, and terminal-notifier runs -execute through
# a shell when clicked, so that branch needs its own coverage with NOTIFY_CMD
# unset. tests/bin/terminal-notifier stands in for the real binary -- it is
# first on PATH for the whole suite, so this is also the only way any test
# here could reach it.
export CC_TN_LOG="${WORK}/terminal-notifier.log"
saved_notify_cmd="$TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_NOTIFY_CMD"
# set -u is active for this whole runner, so notify.sh's direct reference to
# this var needs it bound-but-empty here, not unset -- an unset reference
# would abort the suite rather than take the fallback branch under test.
export TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_NOTIFY_CMD=""

rm -f "$CC_TN_LOG" "$SESSIONS"/*.json
session_file "$SESSIONS" 900030 waiting interactive
notify_case "o'brien:0" "o'brien:0=900030"
# Detached, same as every NOTIFY_CMD case above.
wait 2>/dev/null

export TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_NOTIFY_CMD="$saved_notify_cmd"

# The line after the literal -execute argument is the shell command string
# terminal-notifier would run on click. A correctly escaped apostrophe reads
# as '\'' inside it; an unescaped one would instead have closed the quoted
# argument early and spilled the rest as shell source.
execute_arg=$(grep -A1 '^-execute$' "$CC_TN_LOG" | tail -1)
assert_contains "$execute_arg" "o'\''brien:0" "a single quote in the session name is escaped for -execute, not left to close the argument early"

# The title heads the notification card, which Notification Center draws in the
# system font -- it has no Nerd Font glyphs, so the segment's own label would
# arrive there as a tofu box in front of the window name.
title_arg=$(grep -A1 '^-title$' "$CC_TN_LOG" | tail -1)
assert_eq "$title_arg" "Claude o'brien:0" "the notification title uses the plain-text label, not the bar glyph"
assert_not_contains "$title_arg" "$TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_LABEL" "the bar glyph never reaches a notification title"

# An empty label leaves the window name standing alone, rather than a title
# that starts with a space.
rm -f "$CC_TN_LOG"
saved_notify_label="$TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_NOTIFY_LABEL"
export TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_NOTIFY_LABEL=""
export TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_NOTIFY_CMD=""
notify_case "w1:0" "w1:0=900030"
wait 2>/dev/null
export TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_NOTIFY_CMD="$saved_notify_cmd"
export TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_NOTIFY_LABEL="$saved_notify_label"
assert_eq "$(grep -A1 '^-title$' "$CC_TN_LOG" | tail -1)" "w1:0" "an empty notification label leaves the window name alone"

printf 'run_segment wiring\n'
# Everything above calls a helper directly, so run_segment itself -- the wiring
# that decides which helper runs, and in what order -- has never been executed
# by a test. That includes the invariant this whole branch hangs on: a torn read
# must return before the sync. A regression moving that check below the sync
# would have passed every assertion in this file.

# run_segment derives its cache and blocked-list paths from TMPDIR, and the live
# status bar uses those exact names. Redirect TMPDIR or the suite would clobber
# the running segment's state on the developer's own machine.
export TMPDIR="${WORK}/tmp"
mkdir -p "$TMPDIR"
CC_CACHE="${TMPDIR}/tmux-powerline-claude-sessions.${UID}.cache"

cc_copy_function __cc_sync_windows __cc_real_sync_windows
cc_copy_function __cc_notify __cc_real_notify

CC_SYNC_CALLS=0
CC_NOTIFY_CALLS=0
CC_STATE_AT_NOTIFY=""

__cc_sync_windows() {
	CC_SYNC_CALLS=$((CC_SYNC_CALLS + 1))
	__cc_real_sync_windows "$@"
}

__cc_notify() {
	CC_NOTIFY_CALLS=$((CC_NOTIFY_CALLS + 1))
	# Sampled here, not after run_segment returns: this is the only moment that
	# can distinguish "the sync ran first" from "the sync ran at all".
	CC_STATE_AT_NOTIFY="$(win_state w1:0)"
	__cc_real_notify "$@"
}

# Not `$(run_segment)`: command substitution forks, and a counter incremented by
# a spy in the fork would never be visible here. Same reasoning as cc_load.
seg_run() {
	run_segment >"${WORK}/seg.out"
	# The notifier is deliberately detached so it can never stall a redraw, so
	# any assertion about it has to wait for the fork first.
	wait 2>/dev/null
}

# Re-read the pane pid rather than trusting one captured before the split above.
pid_seg="$(test_window_pid w1:0)"

# A healthy tick: state stamped, frame cached.
rm -f "$SESSIONS"/*.json "$CC_CACHE" "$CC_NOTIFY_LOG"
session_file "$SESSIONS" "$pid_seg" busy interactive
CC_SYNC_CALLS=0
seg_run
good_frame="$(cat "${WORK}/seg.out")"
assert_eq "$CC_SYNC_CALLS" "1" "a healthy read runs the window sync"
assert_eq "$(win_state w1:0)" "busy" "a healthy read stamps the window state"
assert_eq "$(cat "$CC_CACHE" 2>/dev/null)" "$good_frame" "a healthy read caches the frame it printed"

# The invariant. TORN means the read cannot be trusted, so the sync must not run
# at all and every window option must survive untouched -- clearing @cc_state
# here is what would make the next tick read every waiting window as a fresh
# transition and notify on all of them at once.
printf '{"pid":900060,"status":"wait' >"${SESSIONS}/900060.json"
CC_SYNC_CALLS=0
CC_NOTIFY_CALLS=0
seg_run
assert_eq "$CC_SYNC_CALLS" "0" "a torn read never reaches the window sync"
assert_eq "$CC_NOTIFY_CALLS" "0" "a torn read never reaches the notifier"
assert_eq "$(win_state w1:0)" "busy" "a torn read leaves window state untouched"
assert_eq "$(cat "${WORK}/seg.out")" "$good_frame" "a torn read replays the last good frame"

# EMPTY is the opposite: a clean read of a directory with no sessions, so the
# sync does run and strips everything.
rm -f "$SESSIONS"/*.json
CC_SYNC_CALLS=0
seg_run
assert_eq "$CC_SYNC_CALLS" "1" "an empty read runs the window sync"
assert_eq "$(win_state w1:0)" "" "an empty read clears window state"

# Settle at idle so the flip below is a genuine edge rather than a first sight.
rm -f "$SESSIONS"/*.json "$CC_NOTIFY_LOG"
session_file "$SESSIONS" "$pid_seg" idle interactive
seg_run
assert_eq "$(cat "$CC_NOTIFY_LOG" 2>/dev/null)" "" "settling at idle notifies nothing"

# The whole path, end to end: a session file flipping to waiting, through
# collect, through the sync that fills the transitions array, to the array the
# notifier reads and the command it finally runs. The sync must land first --
# by the time __cc_notify runs, @cc_state already reads waiting, which is what
# stops a concurrently running copy of the segment delivering a duplicate.
rm -f "$SESSIONS"/*.json "$CC_NOTIFY_LOG"
session_file "$SESSIONS" "$pid_seg" waiting interactive "" "permission prompt"
CC_NOTIFY_CALLS=0
CC_STATE_AT_NOTIFY="not sampled"
seg_run
assert_eq "$CC_NOTIFY_CALLS" "1" "a flip to waiting reaches the notifier"
assert_eq "$CC_STATE_AT_NOTIFY" "waiting" "the sync lands before the notify, not after"
assert_eq "$(cat "$CC_NOTIFY_LOG" 2>/dev/null)" "$(printf 'w1:0\tpermission prompt')" "a session flipping to waiting notifies end to end"

# Holding at waiting is not an edge, so the next tick must stay quiet.
rm -f "$CC_NOTIFY_LOG"
seg_run
assert_eq "$(cat "$CC_NOTIFY_LOG" 2>/dev/null)" "" "holding at waiting does not re-notify"

rm -f "$SESSIONS"/*.json
seg_run

printf 'count trimming\n'
# At rest the segment used to render `0 0 5`, putting two zeros between the
# label and the only count that says anything. The rule now is: show the groups
# from the highest-priority non-zero state rightwards, and idle alone when
# nothing is non-zero.

# The counts come straight from the session records; whether a record resolves
# to a window is a separate question the pid walk answers. So a state can be
# driven with pids that own no pane, which is the only way to set the three
# counts independently of the one window this suite owns.
counts_case() {
	local w="$1" b="$2" i="$3" n=0
	rm -f "$SESSIONS"/*.json
	for ((n = 0; n < w; n++)); do session_file "$SESSIONS" "$((910000 + n))" waiting interactive; done
	for ((n = 0; n < b; n++)); do session_file "$SESSIONS" "$((920000 + n))" busy interactive; done
	for ((n = 0; n < i; n++)); do session_file "$SESSIONS" "$((930000 + n))" idle interactive; done
	seg_run
}

# What the eye sees, with the tmux style directives taken back out. Asserting on
# the marked-up string would pin the colours too, which belong to the separate
# rule about which state the label takes.
seg_text() {
	sed 's/#\[[^]]*\]//g' "${WORK}/seg.out"
}

L="${TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_LABEL}${TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_LABEL_GAP}"
G="${TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_GAP}"
WG="${TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_WAIT_GLYPH}"
BG="${TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_BUSY_GLYPH}"
IG="${TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_IDLE_GLYPH}"

counts_case 0 0 0
assert_eq "$(seg_text)" "${L}0${G}${IG}" "no sessions renders the idle group alone"
[ -e "$CC_CACHE" ] && cache_state="present" || cache_state="dropped"
assert_eq "$cache_state" "present" "the no-sessions frame replaces the stale one"

counts_case 0 0 5
assert_eq "$(seg_text)" "${L}5${G}${IG}" "idle only renders one group"

counts_case 0 1 5
assert_eq "$(seg_text)" "${L}1${G}${BG}  5${G}${IG}" "busy and idle renders two groups, no leading zero"

# Interior zeros stay. A zero busy beside a non-zero waiting is news: nothing is
# in flight, so neither of those waiting sessions will resolve on its own.
counts_case 2 0 5
assert_eq "$(seg_text)" "${L}2${G}${WG}  0${G}${BG}  5${G}${IG}" "a zero busy between waiting and idle survives"

# Trailing zeros stay too -- trimming both ends would make the width jump around
# non-monotonically as demand changes.
counts_case 2 1 0
assert_eq "$(seg_text)" "${L}2${G}${WG}  1${G}${BG}  0${G}${IG}" "a trailing zero idle survives"

# The bold rides on the waiting count, and the waiting group is exactly the one
# that can now disappear -- so every separator has to carry the reset, or the
# bold leaks into whatever follows it.
counts_case 2 0 5
frame="$(cat "${WORK}/seg.out")"
assert_contains "$frame" ",bold]2" "a non-zero waiting count is bold"
# The first style directive after the waiting glyph is the one that has to clear
# the bold; the fg-only ones after it inherit that. The reset rides on the
# separator, and the separator is what disappears when the waiting group does --
# which is why it is asserted here rather than assumed.
assert_contains "$(printf '%s' "${frame#*"$WG"}" | grep -o '#\[[^]]*\]' | head -1)" "nobold" "the bold is cleared immediately after the waiting count"

counts_case 0 3 5
assert_not_contains "$(cat "${WORK}/seg.out")" ",bold]" "nothing is bold when nothing is waiting"

rm -f "$SESSIONS"/*.json
seg_run

printf 'notification click target\n'
# goto.sh is what a clicked notification runs. Everything it touches is stubbed:
# tmux here must never be the real binary, since the success path runs
# switch-client and would yank the developer's own client to another session,
# and `open` must never actually raise an application.
GOTO="${CC_SEG_DIR}/claude/goto.sh"
GOTO_BIN="${WORK}/gotobin"
mkdir -p "$GOTO_BIN"
cat >"${GOTO_BIN}/tmux" <<'EOS'
#!/bin/sh
printf 'tmux %s\n' "$*" >>"$CC_GOTO_LOG"
[ "$1" = "list-clients" ] && printf '%s\n' "${CC_GOTO_CLIENT:-}"
exit 0
EOS
cat >"${GOTO_BIN}/open" <<'EOS'
#!/bin/sh
printf 'open %s\n' "$*" >>"$CC_GOTO_LOG"
exit 0
EOS
chmod +x "${GOTO_BIN}/tmux" "${GOTO_BIN}/open"
export CC_GOTO_LOG="${WORK}/goto.log"

# tmux on PATH: the ordinary case. Selecting the window is a separate step from
# switching the session, or the click lands on whichever window that session
# last had.
: >"$CC_GOTO_LOG"
CC_GOTO_CLIENT="/dev/ttys009" PATH="${GOTO_BIN}:${PATH}" "$GOTO" "w9:3" "TestApp"
goto_log="$(cat "$CC_GOTO_LOG")"
assert_contains "$goto_log" "tmux switch-client -c /dev/ttys009 -t w9" "the click switches to the target session"
assert_contains "$goto_log" "tmux select-window -t w9:3" "the click selects the target window"

# terminal-notifier runs -execute through /bin/sh -c with its own inherited
# environment, which frequently does not carry /opt/homebrew/bin. Resolving tmux
# from PATH alone meant it was simply not found: no client, no switch, and the
# fall through to `open` raised the terminal on whatever window was last
# current -- indistinguishable from the feature not working.
#
# A PATH with the system utilities but no tmux, which is what terminal-notifier
# actually hands this script. The `open` stub goes first so nothing here can
# raise a real application; head and bash come from /usr/bin and /bin. tmux is
# only ever in /opt/homebrew/bin on this platform, so leaving that out is what
# reproduces the failure.
NOTMUX_BIN="${WORK}/notmuxbin"
mkdir -p "$NOTMUX_BIN"
cp "${GOTO_BIN}/open" "${NOTMUX_BIN}/open"
NOTMUX_PATH="${NOTMUX_BIN}:/usr/bin:/bin"

: >"$CC_GOTO_LOG"
CC_GOTO_CLIENT="/dev/ttys009" CC_GOTO_TMUX_PATHS="${GOTO_BIN}/tmux" \
	PATH="$NOTMUX_PATH" "$GOTO" "w9:3" "TestApp"
goto_log="$(cat "$CC_GOTO_LOG")"
assert_contains "$goto_log" "tmux select-window -t w9:3" "tmux missing from PATH still resolves and selects the window"

# No tmux anywhere. The terminal still comes up, but the failure has to be
# recoverable by a later debugger rather than silent, so it exits non-zero.
: >"$CC_GOTO_LOG"
CC_GOTO_TMUX_PATHS="${WORK}/no-such-tmux" PATH="$NOTMUX_PATH" "$GOTO" "w9:3" "TestApp" &&
	goto_rc=0 || goto_rc=$?
assert_eq "$goto_rc" "1" "an unresolvable tmux fails loudly rather than silently"
assert_contains "$(cat "$CC_GOTO_LOG")" "open -a TestApp" "the terminal is still raised when tmux cannot be found"

# An empty target is a no-op, not a switch to nothing.
: >"$CC_GOTO_LOG"
PATH="${GOTO_BIN}:${PATH}" "$GOTO" "" "TestApp"
assert_eq "$(cat "$CC_GOTO_LOG")" "" "an empty target does nothing at all"

printf '\n%d passed, %d failed\n' "$CC_PASS" "$CC_FAIL"
[ "$CC_FAIL" -eq 0 ]
