#!/usr/bin/env bash
# Tests for install-hooks.sh, against throwaway settings files.
#
# What makes this worth testing is that it edits a file it does not own. Claude
# Code writes settings.json itself and so does the user, so the two failures
# that matter are silent in opposite directions: registering twice (the same
# hook fires twice per event, and for SessionStart that is the skill pasted into
# the context twice), or registering over somebody else's hook.
#
#   ./install-hooks.test.sh

set -u

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
INSTALL="$(cd .. && pwd)/install-hooks.sh"

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
		fail "$3" "expected: [$1]" "got:      [$2]"
	fi
}

S="${WORK}/settings.json"
WAITING="~/.claude/hooks/claude-waiting.sh"
SKILLS="~/.claude/hooks/session-start-skills.sh"
LEGACY="cat ~/.claude/skills/unslop/SKILL.md"

install() { "$INSTALL" "$S" >/dev/null; }

# How many hooks in event $1 run command $2.
count() { # event command
	jq --arg cmd "$2" "[.hooks[\"$1\"][]?.hooks[]? | select(.command == \$cmd)] | length" "$S"
}
q() { jq -r "$1" "$S"; }

# A machine with no settings file at all, which is what a fresh checkout is.
rm -f "$S"
install
assert_eq "1" "$(count Stop "$WAITING")" "creates settings.json and registers the waiting hook"
assert_eq "1" "$(count SessionStart "$SKILLS")" "registers the skills hook"
assert_eq "startup|clear|compact" "$(q '.hooks.SessionStart[0].matcher')" \
	"the skills hook carries its matcher"
assert_eq "null" "$(q '.hooks.Stop[0].matcher')" \
	"the waiting hook is registered without one"

# The skills hook runs on two events, not one. SessionStart alone puts the skill
# 100k tokens behind the response it is meant to govern by the end of a long
# session; UserPromptSubmit puts it back in front of every turn. No matcher
# here, because there are no prompt kinds to select between.
assert_eq "1" "$(count UserPromptSubmit "$SKILLS")" \
	"registers the skills hook on UserPromptSubmit too"
assert_eq "1" "$(count UserPromptSubmit "$WAITING")" \
	"and leaves the waiting hook already on that event alone"

# install.zsh runs this on every stow, so the second run is the normal case.
install
install
assert_eq "1" "$(count Stop "$WAITING")" "re-running does not register the waiting hook twice"
assert_eq "1" "$(count SessionStart "$SKILLS")" "re-running does not register the skills hook twice"
assert_eq "1" "$(count UserPromptSubmit "$SKILLS")" \
	"re-running does not register the per-turn injection twice"

# The hand-written predecessor. Both would fire, so the session would open with
# the skill in its context twice over.
printf '%s\n' '{"hooks":{"SessionStart":[{"matcher":"startup|clear|compact","hooks":[{"type":"command","command":"cat ~/.claude/skills/unslop/SKILL.md","shell":"bash","async":false}]}]}}' >"$S"
install
assert_eq "0" "$(count SessionStart "$LEGACY")" "retires the hand-registered cat"
assert_eq "1" "$(count SessionStart "$SKILLS")" "and leaves the script in its place"

# Everything else in the file belongs to Claude Code or to the user. A hook
# registered for another purpose, on an event this script also writes to, is the
# case where an over-eager installer does real damage.
printf '%s\n' '{"model":"opus","hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"echo mine"}]}],"PreToolUse":[{"hooks":[{"type":"command","command":"echo pre"}]}]}}' >"$S"
install
assert_eq "1" "$(count SessionStart "echo mine")" "leaves someone else's hook on the same event"
assert_eq "1" "$(count PreToolUse "echo pre")" "leaves an event it does not manage"
assert_eq "opus" "$(q '.model')" "leaves unrelated settings"

# An entry emptied by the retirement goes with it. Keeping the husk would leave
# SessionStart holding an entry that runs nothing, which reads as a hook that
# stopped working rather than one that was replaced.
printf '%s\n' '{"hooks":{"SessionStart":[{"matcher":"startup","hooks":[{"type":"command","command":"cat ~/.claude/skills/unslop/SKILL.md"}]}]}}' >"$S"
install
assert_eq "1" "$(q '.hooks.SessionStart | length')" \
	"an entry left empty by the retirement is dropped, not kept"

# Invalid JSON is the user's file in a state this script must not make worse:
# jq cannot read it, so there is nothing to merge into and nothing to write.
printf '%s\n' '{not json' >"$S"
if "$INSTALL" "$S" >/dev/null 2>&1; then
	fail "refuses to write over unreadable settings" "exited 0"
else
	assert_eq "{not json" "$(cat "$S")" "refuses to write over unreadable settings"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
