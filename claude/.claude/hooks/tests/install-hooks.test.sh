#!/usr/bin/env bash
# Tests for install-hooks.sh, against throwaway settings files.
#
# What makes this worth testing is that it edits a file it does not own. Claude
# Code writes settings.json itself and so does the user, so the two failures
# that matter are silent in opposite directions: registering twice, so the same
# hook fires twice per event, or registering over somebody else's hook. A third
# followed from deleting the unslop hooks. A registration left behind pointing
# at a script that is gone fails on every turn, so the retirements are tested
# the same way the registrations are.
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
SRCSYNC="~/.claude/hooks/srcsync-hook.sh"
# All three retired. unslop is imported by ~/.claude/CLAUDE.md now.
SKILLS="~/.claude/hooks/session-start-skills.sh"
TURN="~/.claude/hooks/turn-skill-reminder.sh"
LEGACY="cat ~/.claude/skills/unslop/SKILL.md"

# srcsync is installed on its own, so its hook follows whether srcsync.sh is
# there. Most cases run with it installed.
BIN="${WORK}/srcsync.sh"
touch "$BIN"
install() { SRCSYNC_BIN="$BIN" "$INSTALL" "$S" >/dev/null; }

# How many hooks in event $1 run command $2.
count() { # event command
	jq --arg cmd "$2" "[.hooks[\"$1\"][]?.hooks[]? | select(.command == \$cmd)] | length" "$S"
}
q() { jq -r "$1" "$S"; }

# A machine with no settings file at all, which is what a fresh checkout is.
rm -f "$S"
install
assert_eq "1" "$(count Stop "$WAITING")" "creates settings.json and registers the waiting hook"
assert_eq "1" "$(count UserPromptSubmit "$WAITING")" \
	"and on every other event it claims"
assert_eq "null" "$(q '.hooks.Stop[0].matcher')" \
	"the waiting hook is registered without a matcher"

# The waiting hook is the only one left. A fresh machine must not acquire a
# SessionStart entry at all, since retiring something must never invent the
# event it was retired from.
assert_eq "null" "$(q '.hooks.SessionStart')" \
	"invents no SessionStart on a machine that never had one"
assert_eq "0" "$(count UserPromptSubmit "$TURN")" "registers no per-turn reminder"

assert_eq "1" "$(count Stop "$SRCSYNC")" "and, with srcsync installed, its hook on Stop"
assert_eq "1" "$(count SessionEnd "$SRCSYNC")" "and on SessionEnd"

# install.zsh runs this on every stow, so the second run is the normal case.
install
install
assert_eq "1" "$(count Stop "$WAITING")" "re-running does not register the waiting hook twice"
assert_eq "1" "$(count UserPromptSubmit "$WAITING")" \
	"nor on UserPromptSubmit, where two hooks used to sit"
assert_eq "1" "$(count Stop "$SRCSYNC")" "nor the srcsync hook on Stop"
assert_eq "1" "$(count SessionEnd "$SRCSYNC")" "nor on SessionEnd"

# install-srcsync.zsh off unstows srcsync.sh, then runs this to drop the hook.
rm -f "$BIN"
install
assert_eq "0" "$(count Stop "$SRCSYNC")" "drops the srcsync hook from Stop once srcsync is gone"
assert_eq "0" "$(count SessionEnd "$SRCSYNC")" "and from SessionEnd"
assert_eq "1" "$(count Stop "$WAITING")" "and keeps the waiting hook"
rm -f "$S"
install
assert_eq "0" "$(count Stop "$SRCSYNC")" "a machine without srcsync never gets its hook"
touch "$BIN"

# The hand-written predecessor, from before any of this was a script.
printf '%s\n' '{"hooks":{"SessionStart":[{"matcher":"startup|clear|compact","hooks":[{"type":"command","command":"cat ~/.claude/skills/unslop/SKILL.md","shell":"bash","async":false}]}]}}' >"$S"
install
assert_eq "0" "$(count SessionStart "$LEGACY")" "retires the hand-registered cat"

# What a machine looks like on the stow that follows this change: both unslop
# hooks registered against scripts that no longer exist.
printf '%s\n' '{"hooks":{"SessionStart":[{"matcher":"startup|clear|compact","hooks":[{"type":"command","command":"~/.claude/hooks/session-start-skills.sh"}]}],"UserPromptSubmit":[{"hooks":[{"type":"command","command":"~/.claude/hooks/turn-skill-reminder.sh"}]}]}}' >"$S"
install
assert_eq "0" "$(count SessionStart "$SKILLS")" "retires the session-start injection"
assert_eq "0" "$(count UserPromptSubmit "$TURN")" "retires the per-turn reminder"
assert_eq "1" "$(count UserPromptSubmit "$WAITING")" \
	"and the waiting hook takes the place it left"

# An earlier version of the script put the whole skill on UserPromptSubmit too.
printf '%s\n' '{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"~/.claude/hooks/session-start-skills.sh"}]}]}}' >"$S"
install
assert_eq "0" "$(count UserPromptSubmit "$SKILLS")" "retires the full skill from UserPromptSubmit"

# The theme is the one key written by value rather than matched by command, so
# the failure it can cause is the opposite of a duplicate: overwriting a choice
# someone made in /theme. install.zsh runs this on every stow, so that would
# undo the pick on the next unrelated install.
rm -f "$S"
install
assert_eq "custom:ayu-dark" "$(q '.theme')" "sets the theme on a machine with no settings"

printf '%s\n' '{"theme":"dark-daltonized"}' >"$S"
install
assert_eq "dark-daltonized" "$(q '.theme')" "leaves a theme the user already chose"

# Claude Code writing the key with no value is not a choice either.
printf '%s\n' '{"theme":null}' >"$S"
install
assert_eq "custom:ayu-dark" "$(q '.theme')" "fills a null theme"

# Everything else in the file belongs to Claude Code or to the user. A hook
# registered for another purpose, on an event this script also writes to, is the
# case where an over-eager installer does real damage.
printf '%s\n' '{"model":"opus","hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"echo mine"}]}],"PreToolUse":[{"hooks":[{"type":"command","command":"echo pre"}]}]}}' >"$S"
install
assert_eq "1" "$(count SessionStart "echo mine")" "leaves someone else's hook on the same event"
assert_eq "1" "$(count PreToolUse "echo pre")" "leaves an event it does not manage"
assert_eq "opus" "$(q '.model')" "leaves unrelated settings"

# An entry emptied by the retirement goes with it, and so does the event once
# nothing is left on it. Keeping the husk would leave SessionStart holding an
# entry that runs nothing, which reads as a hook that stopped working rather
# than one that was removed.
printf '%s\n' '{"hooks":{"SessionStart":[{"matcher":"startup","hooks":[{"type":"command","command":"cat ~/.claude/skills/unslop/SKILL.md"}]}]}}' >"$S"
install
assert_eq "null" "$(q '.hooks.SessionStart')" \
	"an entry left empty by the retirement is dropped, and the empty event with it"

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
