#!/usr/bin/env bash
# Tests for live-sessions.sh, against a throwaway tmux server on its own socket.
#
# A real server rather than a stubbed `tmux`, because the two facts this whole
# design rests on are facts about tmux itself and a stub would assert them into
# existence: that a `session-closed` hook sees the post-close session list, and
# that a server killed by a signal -- what a reboot does -- fires no hooks at
# all, so the file survives the reboot it is meant to survive.
#
# The empty-list guard is the other half of that. `tmux kill-server` was
# measured firing the hook once for two sessions, so the last write before a
# server goes away can arrive with a truncated list or none at all, and a
# recorder that trusted it would erase the list at exactly the moment it is
# needed.
#
#   ./live-sessions.test.sh

set -u

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
SCRIPT="$(cd .. && pwd)/live-sessions.sh"

WORK="$(mktemp -d)"
SOCKET="ls-test-$$"
trap 'tmux -L "$SOCKET" kill-server 2>/dev/null; rm -rf "$WORK"' EXIT

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
assert_eq() { # want got label
	if [ "$1" = "$2" ]; then pass "$3"; else
		fail "$3" "expected: $(printf '%q' "$1")" "got:      $(printf '%q' "$2")"
	fi
}

# tmux is asynchronous about run-shell, so a hook's effect is not on disk the
# instant the command that triggered it returns. Poll rather than sleep a fixed
# amount: the wait is usually a few milliseconds and only the failure case pays.
settle_until() { # predicate-command...
	local n=0
	while [ $n -lt 100 ]; do
		"$@" && return 0
		perl -e 'select(undef,undef,undef,0.02)'
		n=$((n + 1))
	done
	return 1
}

LIVE="${WORK}/.live-sessions"
DIRS="${WORK}/.session-dirs"

export LS_FILE="$LIVE"
export LS_DIRS="$DIRS"
export LS_TMUX="tmux -L $SOCKET"

tmux -L "$SOCKET" kill-server 2>/dev/null
tmux -L "$SOCKET" new-session -d -s alpha
tmux -L "$SOCKET" new-session -d -s beta

recorded() { sort "$LIVE" 2>/dev/null | tr '\n' ' '; }

# --- recording -------------------------------------------------------------

"$SCRIPT"
assert_eq "alpha beta " "$(recorded)" "records every live session, one per line"

"$SCRIPT"
"$SCRIPT"
assert_eq "alpha beta " "$(recorded)" "rewrites rather than appends"

# The guard. Told there are no sessions -- which is what a server on its way out
# reports -- the file must be left exactly as it was.
LS_TMUX="tmux -L no-such-socket-$$" "$SCRIPT"
assert_eq "alpha beta " "$(recorded)" "an empty session list leaves the file alone"

# --- hooks -----------------------------------------------------------------

tmux -L "$SOCKET" set-hook -g session-created "run-shell $SCRIPT"
tmux -L "$SOCKET" set-hook -g session-closed "run-shell $SCRIPT"

# The hook body must carry no '#'. tmux format-expands a hook string before
# running it, so a '#S' meant for the shell is replaced with the hook's own
# session name before the shell ever sees it.
tmux -L "$SOCKET" new-session -d -s gamma
settle_until grep -qx gamma "$LIVE"
assert_eq "alpha beta gamma " "$(recorded)" "session-created adds the new session"

tmux -L "$SOCKET" kill-session -t beta
settle_until bash -c '! grep -qx beta "$0"' "$LIVE"
assert_eq "alpha gamma " "$(recorded)" "session-closed drops the killed session"

# --- surviving a reboot ----------------------------------------------------

# SIGTERM is what a reboot delivers. No hook runs, so the file still names every
# session that was live -- which is the entire point of keeping it.
before="$(recorded)"
# Stated rather than assumed. Comparing the file to itself across the kill
# passes trivially when the file is empty or absent, which is the one outcome
# this test exists to rule out.
[ -n "$before" ] || fail "a server killed by signal leaves the list intact" \
	"nothing was recorded before the kill, so the comparison proves nothing"
srv=$(tmux -L "$SOCKET" display-message -p '#{pid}')
kill -TERM "$srv"
while kill -0 "$srv" 2>/dev/null; do :; done
perl -e 'select(undef,undef,undef,0.3)'
assert_eq "$before" "$(recorded)" "a server killed by signal leaves the list intact"

# --- restorable ------------------------------------------------------------

# Sourced for the reader, which is how sessionizer.sh uses it. Sourcing must not
# record: the picker asks what is restorable, and answering must not rewrite the
# very list it is reading.
snapshot="$(cat "$LIVE")"
[ -n "$snapshot" ] || fail "sourcing the script records nothing" \
	"the file was already empty, so the comparison proves nothing"
# shellcheck source=../live-sessions.sh
source "$SCRIPT"
assert_eq "$snapshot" "$(cat "$LIVE")" "sourcing the script records nothing"

printf 'alpha\t%s/alpha\n' "$WORK" >"$DIRS"
printf 'gamma\t%s/gamma\n' "$WORK" >>"$DIRS"
printf 'delta\t%s/delta\n' "$WORK" >>"$DIRS"
mkdir -p "${WORK}/alpha" "${WORK}/gamma" "${WORK}/delta"

printf 'gamma\nalpha\ndelta\n' >"$LIVE"

assert_eq "gamma delta" "$(ls_restorable alpha | tr '\n' ' ' | sed 's/ $//')" \
	"restorable excludes sessions that are already running"

assert_eq "gamma alpha delta" "$(ls_restorable | tr '\n' ' ' | sed 's/ $//')" \
	"restorable keeps the recorded order"

# A worktree removed since the session was recorded. Rebuilding it would land a
# session named for the branch in whatever directory the fallback chose, so the
# row has to go rather than be offered.
rm -rf "${WORK}/gamma"
assert_eq "alpha delta" "$(ls_restorable | tr '\n' ' ' | sed 's/ $//')" \
	"restorable drops a session whose directory is gone"

# Same reasoning, one step earlier: without a recorded directory there is
# nothing to rebuild from at all.
printf 'alpha\nunmapped\ndelta\n' >"$LIVE"
assert_eq "alpha delta" "$(ls_restorable | tr '\n' ' ' | sed 's/ $//')" \
	"restorable drops a session with no recorded directory"

# The file not existing yet is the state of a machine that has not run the hook
# once. It means nothing is restorable, not that something failed.
rm -f "$LIVE"
assert_eq "" "$(ls_restorable)" "a missing file yields nothing"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
