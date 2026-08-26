#!/usr/bin/env bash
# Tests for claude-continue.sh: does the claude window ask to continue, or not.
#
# The whole script is one decision, and both ways of getting it wrong are quiet.
# Asking to continue where there is nothing lands you on "No conversation found
# to continue" and a bare shell, which is the bug this replaced. Not asking
# where there is something loses the conversation a rebuilt session exists to
# bring back, and looks like a working window until you go looking for it.
#
# `claude` is stubbed here because what is under test is the argument list, and
# a real Claude would want the network and a login to tell us the same thing.
#
#   ./claude-continue.test.sh

set -u

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
SCRIPT="$(cd .. && pwd)/claude-continue.sh"

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
assert_eq() { # want got label
	if [ "$1" = "$2" ]; then pass "$3"; else
		fail "$3" "expected: $(printf '%q' "$1")" "got:      $(printf '%q' "$2")"
	fi
}

# The stub stands in for the real binary by name, so the script under test needs
# no hook to accept it -- exactly the resolution the tmux window does.
mkdir -p "${WORK}/bin"
cat >"${WORK}/bin/claude" <<'STUB'
#!/bin/sh
printf '%s\n' "$*"
STUB
chmod +x "${WORK}/bin/claude"

PROJECTS="${WORK}/projects"

# What the claude window would run in $1, as the argument list claude receives.
launched() { # dir
	(
		cd "$1" || exit 1
		PATH="${WORK}/bin:$PATH" CC_PROJECTS_DIR="$PROJECTS" "$SCRIPT" -n demo
	)
}

# Claude's own name for a directory. Recomputed here rather than imported: if
# the script's idea of it ever drifts from this one, every lookup silently
# misses and every session starts fresh, which is a failure worth a red test.
slug() { # dir
	printf '%s' "$(cd "$1" && pwd -P)" | tr -c 'A-Za-z0-9' '-'
}

# A directory Claude has never seen -- the new session this all started with.
mkdir -p "${WORK}/fresh"
assert_eq "-n demo" "$(launched "${WORK}/fresh")" \
	"a directory with no history starts a fresh Claude"

# And one it has: a rebuilt session has to come back where it left off.
mkdir -p "${WORK}/known"
mkdir -p "${PROJECTS}/$(slug "${WORK}/known")"
echo '{"type":"user"}' >"${PROJECTS}/$(slug "${WORK}/known")/abc.jsonl"
assert_eq "-c -n demo" "$(launched "${WORK}/known")" \
	"a directory with a transcript continues it"

# A session that died before its first turn leaves the directory behind with an
# empty transcript in it. There is nothing there to continue, so treating it as
# history would put the window straight back on the error.
mkdir -p "${WORK}/stillborn"
mkdir -p "${PROJECTS}/$(slug "${WORK}/stillborn")"
: >"${PROJECTS}/$(slug "${WORK}/stillborn")/abc.jsonl"
assert_eq "-n demo" "$(launched "${WORK}/stillborn")" \
	"an empty transcript counts as no history"

# Claude keeps per-session working state in sub-directories next to the
# transcripts. A directory holding only those holds no conversation.
mkdir -p "${WORK}/statefully"
mkdir -p "${PROJECTS}/$(slug "${WORK}/statefully")/abc"
assert_eq "-n demo" "$(launched "${WORK}/statefully")" \
	"sub-directories alone count as no history"

# The dashing rule is per character, not per path separator: a dot or an
# underscore in a directory name becomes a dash like a slash does. Worktree
# names carry both, so getting this wrong would strand real sessions.
mkdir -p "${WORK}/my.repo_x"
mkdir -p "${PROJECTS}/$(slug "${WORK}/my.repo_x")"
echo '{"type":"user"}' >"${PROJECTS}/$(slug "${WORK}/my.repo_x")/abc.jsonl"
assert_eq "-c -n demo" "$(launched "${WORK}/my.repo_x")" \
	"punctuation in the path resolves to the right project"

# Reached through a symlink, it is still the same directory, and Claude will
# file the conversation under the path it resolves to.
ln -s "${WORK}/my.repo_x" "${WORK}/link-to-repo"
assert_eq "-c -n demo" "$(launched "${WORK}/link-to-repo")" \
	"a symlinked path finds the real directory's history"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
