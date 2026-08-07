# shellcheck shell=bash
# Assertions and fixtures for the Claude sessions segment tests.

CC_TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CC_SEG_DIR="$(cd "${CC_TESTS_DIR}/../.." && pwd)"

CC_PASS=0
CC_FAIL=0

pass() {
	CC_PASS=$((CC_PASS + 1))
	printf '  ok   %s\n' "$1"
}

fail() {
	CC_FAIL=$((CC_FAIL + 1))
	printf '  FAIL %s\n' "$1"
	shift
	local line
	for line in "$@"; do printf '         %s\n' "$line"; done
}

assert_eq() {
	if [ "$1" = "$2" ]; then
		pass "$3"
	else
		fail "$3" "expected: [$2]" "actual:   [$1]"
	fi
}

assert_contains() {
	case "$1" in
	*"$2"*) pass "$3" ;;
	*) fail "$3" "expected to contain: [$2]" "actual: [$1]" ;;
	esac
}

assert_not_contains() {
	case "$1" in
	*"$2"*) fail "$3" "expected NOT to contain: [$2]" "actual: [$1]" ;;
	*) pass "$3" ;;
	esac
}

# Write one session status file. Mirrors the real shape written by the CLI:
# every live session file is an interactive one, carrying a sessionId that a
# background agent's job state refers back to.
# Usage: session_file <dir> <pid> <status> <kind> [sessionId] [waitingFor]
session_file() {
	local dir="$1" pid="$2" status="$3" kind="$4"
	local sid="${5:-}" waiting="${6:-}"
	local json="{\"pid\":${pid},\"status\":\"${status}\",\"kind\":\"${kind}\""
	[ -n "$sid" ] && json="${json},\"sessionId\":\"${sid}\""
	[ -n "$waiting" ] && json="${json},\"waitingFor\":\"${waiting}\""
	printf '%s}\n' "$json" >"${dir}/${pid}.json"
}

# Write one background-agent job state file, as the daemon writes it under
# ~/.claude/jobs/<id>/state.json. sessionId is the link back to the interactive
# session that owns the agent -- there is no pid here, and no session file
# either, which is the whole reason the old jobId/parkedJobId path never fired.
# Usage: job_file <jobs_dir> <id> <state> <sessionId>
job_file() {
	local dir="$1" id="$2" state="$3" sid="$4"
	mkdir -p "${dir}/${id}"
	printf '{"state":"%s","sessionId":"%s","name":"%s"}\n' "$state" "$sid" "$id" \
		>"${dir}/${id}/state.json"
}

# Write one hook waiting marker, as claude-waiting.sh writes it. Named for the
# sessionId, exactly like a job's sessionId link -- there is no pid here either.
# A `.pending` suffix is the half-state: Claude asked, but idle_prompt has not
# yet confirmed nobody answered, and collect.sh must ignore those.
# Usage: mark_file <marks_dir> <sessionId> [reason] [text] [pending]
mark_file() {
	local dir="$1" sid="$2" reason="${3:-question}" text="${4:-any more?}"
	local suffix=""
	[ "${5:-}" = "pending" ] && suffix=".pending"
	mkdir -p "$dir"
	printf '%s\t%s\n' "$reason" "$text" >"${dir}/${sid}${suffix}"
}

# Start a throwaway tmux server. Every tmux call made by the code under test
# reaches this server via the PATH shim, never the users own server.
test_tmux_start() {
	export CC_REAL_TMUX="${CC_REAL_TMUX:-$(command -v tmux)}"
	export CC_TMUX_SOCKET="cctest-$$"
	PATH="${CC_TESTS_DIR}/bin:${PATH}"
	export PATH
	tmux kill-server 2>/dev/null
	tmux new-session -d -s w1 -x 200 -y 50
	tmux new-window -t w1
}

test_tmux_stop() {
	tmux kill-server 2>/dev/null
	return 0
}

# The pid of the shell running in a windows only pane. Fixtures use this as a
# session pid so the parent walk in __cc_collect terminates immediately.
test_window_pid() {
	tmux list-panes -t "$1" -F '#{pane_pid}' 2>/dev/null | head -1
}

# Source the segment under test. Produces no output if the segment is well
# formed, which is itself asserted in run.sh.
cc_load() {
	# shellcheck disable=SC1090,SC1091
	source "${CC_SEG_DIR}/claude_sessions.sh"
}

# The @cc_state of one window, empty when unset.
#
# show-options -wv errors on an option that has never been set, which is
# precisely the case a cleared window is in, so read the listing instead --
# that always succeeds.
win_state() {
	tmux list-windows -a -F '#{session_name}:#{window_index} #{@cc_state}' 2>/dev/null |
		awk -v w="$1" '$1 == w { print $2 }'
}

# Copy a function under a second name, so a test can replace the original with a
# spy that still calls through to the real behaviour. `declare -f` prints a
# valid definition and only the name on its first line needs rewriting.
cc_copy_function() {
	eval "$(declare -f "$1" | sed "1s/^${1}/${2}/")"
}
