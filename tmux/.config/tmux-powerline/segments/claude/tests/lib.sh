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

# Write one session status file. Mirrors the real shape written by the CLI.
# Usage: session_file <dir> <pid> <status> <kind> [jobId] [parkedJobId] [waitingFor]
session_file() {
	local dir="$1" pid="$2" status="$3" kind="$4"
	local job="${5:-}" parked="${6:-}" waiting="${7:-}"
	local json="{\"pid\":${pid},\"status\":\"${status}\",\"kind\":\"${kind}\""
	[ -n "$job" ] && json="${json},\"jobId\":\"${job}\""
	[ -n "$parked" ] && json="${json},\"parkedJobId\":\"${parked}\""
	[ -n "$waiting" ] && json="${json},\"waitingFor\":\"${waiting}\""
	printf '%s}\n' "$json" >"${dir}/${pid}.json"
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
