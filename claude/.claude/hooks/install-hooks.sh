#!/usr/bin/env bash
# Register this directory's hooks in ~/.claude/settings.json.
#
# settings.json is deliberately NOT stowed. Claude Code writes to it itself --
# /permissions, plugin toggles, model choice -- and a program that saves by
# writing a temp file and renaming it over the target would replace the symlink
# with a regular file. The package would look installed, and would silently
# stop tracking. So the scripts are stowed and the reference to them is merged
# in here instead.
#
# Two registrations, for the two things the hooks dir does:
#
#   claude-waiting.sh        marks a session as waiting on you (Stop,
#                            Notification, UserPromptSubmit, SessionEnd)
#   session-start-skills.sh  injects the always-on skills (SessionStart)
#   turn-skill-reminder.sh   re-states the three rules that break (UserPromptSubmit)
#
# Two events, because one was measured not to be enough, and two payloads,
# because the same 80 lines repeated every turn is the wrong shape for the
# second one. A session opened with /clear carried the whole of unslop from its
# first token and still put 35 em dashes into 60 replies. Nothing was missing
# from the context; the rules were just a long way behind the text by the time
# each reply got written. So SessionStart keeps the full skill and
# UserPromptSubmit carries three rules, which is 98.5% of the measured
# violations at 69 tokens a turn instead of 1731.
#
# Both are bets on recency rather than checks. Neither detects anything. Worth
# keeping only if the count drops, so count em dashes in a transcript before
# believing either one works.
#
# Idempotent, and additive per event: an entry is appended only when no existing
# one already runs this command, so hooks configured for other purposes survive.
#
#   ./install-hooks.sh [settings.json]

set -eu

SETTINGS="${1:-${HOME}/.claude/settings.json}"
CMD="${CC_HOOK_CMD:-~/.claude/hooks/claude-waiting.sh}"
SKILLS_CMD="${CC_SKILLS_HOOK_CMD:-~/.claude/hooks/session-start-skills.sh}"
TURN_CMD="${CC_TURN_HOOK_CMD:-~/.claude/hooks/turn-skill-reminder.sh}"

# resume is left out on purpose: a resumed session already carries the context
# these skills were injected into, and injecting them again would pay for the
# same tokens twice.
SKILLS_MATCHER="${CC_SKILLS_HOOK_MATCHER:-startup|clear|compact}"

# What this replaces: the same idea registered by hand, as a literal `cat` in
# settings.json. Left in place it would print the skill a second time on every
# session start, so it is retired here rather than reported. Matched on the
# exact command, so a `cat` of anything else is somebody else's hook and stays.
LEGACY_SKILLS_CMD="${CC_LEGACY_SKILLS_HOOK_CMD:-cat ~/.claude/skills/unslop/SKILL.md}"

command -v jq >/dev/null 2>&1 || {
	echo "install-hooks: jq is required" >&2
	exit 1
}

[ -e "$SETTINGS" ] || printf '{}\n' >"$SETTINGS"

tmp="${SETTINGS}.tmp.$$"
trap 'rm -f "$tmp"' EXIT

jq --arg cmd "$CMD" --arg skills_cmd "$SKILLS_CMD" --arg turn_cmd "$TURN_CMD" \
	--arg skills_matcher "$SKILLS_MATCHER" --arg legacy "$LEGACY_SKILLS_CMD" '
	def entry($cmd; $matcher):
		{hooks: [{type: "command", command: $cmd}]}
		| if $matcher == "" then . else {matcher: $matcher} + . end;

	def ensure($ev; $cmd; $matcher):
		.hooks[$ev] = (
			(.hooks[$ev] // [])
			| if any(.[]; (.hooks // []) | any(.command == $cmd))
			  then .
			  else . + [entry($cmd; $matcher)]
			  end
		);

	# Drops one command wherever it appears in an event, and any entry left
	# holding no hooks. Guarded on the event existing so retiring something
	# never invents an empty list for an event that had none.
	def retire($ev; $cmd):
		if (.hooks[$ev] // null) == null then .
		else
			.hooks[$ev] = (
				.hooks[$ev]
				| map(.hooks = ((.hooks // []) | map(select(.command != $cmd))))
				| map(select((.hooks | length) > 0))
			)
			| if (.hooks[$ev] | length) == 0 then del(.hooks[$ev]) else . end
		end;

	(.hooks //= {})
	| ensure("Stop"; $cmd; "")
	| ensure("Notification"; $cmd; "")
	| ensure("UserPromptSubmit"; $cmd; "")
	| ensure("SessionEnd"; $cmd; "")
	| retire("SessionStart"; $legacy)
	| ensure("SessionStart"; $skills_cmd; $skills_matcher)
	# An earlier version of this script put the whole skill here. Both would
	# fire, so the turn would carry the full rules and the reminder on top.
	| retire("UserPromptSubmit"; $skills_cmd)
	| ensure("UserPromptSubmit"; $turn_cmd; "")
' "$SETTINGS" >"$tmp"

# Replace only once the new content is known to be valid JSON. Truncating the
# user's settings on a jq quirk would be a bad way to find out about it.
jq -e . "$tmp" >/dev/null

mv -f "$tmp" "$SETTINGS"
trap - EXIT

echo "install-hooks: ${CMD}, ${SKILLS_CMD} and ${TURN_CMD} registered in ${SETTINGS}"
