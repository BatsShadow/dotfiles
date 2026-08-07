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

# A busy session in the same window outranks the idle one.
pid_w1b="$(tmux list-panes -t w1:0 -F '#{pane_pid}' | head -1)"
session_file "$SESSIONS" "$((pid_w1b + 100000))" busy interactive
raw="$(__cc_collect "$SESSIONS" "")"
assert_contains "$raw" "COUNTS 0 1 1" "busy and idle counted separately"

rm -f "$SESSIONS"/*.json

# Most demanding state wins when two sessions share one window.
session_file "$SESSIONS" "$pid_w1" busy interactive
raw="$(__cc_collect "$SESSIONS" "")"
assert_contains "$raw" "WIN w1:0 busy" "busy wins over nothing"

rm -f "$SESSIONS"/*.json
session_file "$SESSIONS" "$pid_w1" waiting interactive
raw="$(__cc_collect "$SESSIONS" "")"
assert_contains "$raw" "WIN w1:0 waiting" "waiting is reported"

printf 'empty\n'
rm -f "$SESSIONS"/*.json
raw="$(__cc_collect "$SESSIONS" "")"
assert_eq "$raw" "EMPTY" "an empty sessions directory yields EMPTY"

printf '\n%d passed, %d failed\n' "$CC_PASS" "$CC_FAIL"
[ "$CC_FAIL" -eq 0 ]
