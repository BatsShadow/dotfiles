#!/usr/bin/env bash
# Merge this directory's hook registrations and theme choice into
# ~/.claude/settings.json.
#
# settings.json is deliberately NOT stowed. Claude Code writes to it itself --
# /permissions, plugin toggles, model choice -- and a program that saves by
# writing a temp file and renaming it over the target would replace the symlink
# with a regular file. The package would look installed, and would silently
# stop tracking. So the scripts are stowed and the reference to them is merged
# in here instead.
#
# One registration now, for the one thing the hooks dir still does:
#
#   claude-waiting.sh  marks a session as waiting on you (Stop, Notification,
#                      UserPromptSubmit, SessionEnd)
#
# srcsync-hook.sh is registered the same way, on Stop and SessionEnd, to
# trigger srcsync's own auto command.
#
# It used to register two more, which injected unslop at session start and
# re-stated its three worst rules every turn. Claude Code loads the rules
# itself now, because ~/.claude/CLAUDE.md imports references/unslop.md and
# expands the import before the first reply. The scripts are deleted, so the
# job here is to take their registrations back out of settings.json on every
# machine that ran the old version. A registration left pointing at a deleted
# script is a hook error on every turn.
#
# The theme is here for the reason the hooks are. themes/ is stowed, so
# ayu-dark.json travels with the repo, but the choice of which theme is active
# is a settings.json key and does not. A fresh machine got the file and came up
# on the default.
#
# Written only when the key is absent, which is the one place this script
# differs from the hooks. Those are matched on command, so a second entry is
# always wrong. There is exactly one theme key, and anything already in it is a
# deliberate answer, so install.zsh re-running this on every stow must not
# overwrite a later pick from /theme.
#
# Idempotent, and additive per event: an entry is appended only when no existing
# one already runs this command, so hooks configured for other purposes survive.
#
#   ./install-hooks.sh [settings.json]

set -eu

SETTINGS="${1:-${HOME}/.claude/settings.json}"
CMD="${CC_HOOK_CMD:-~/.claude/hooks/claude-waiting.sh}"
SRCSYNC="${CC_SRCSYNC_HOOK_CMD:-~/.claude/hooks/srcsync-hook.sh}"
THEME="${CC_THEME:-custom:ayu-dark}"

# The three retired commands, oldest first: unslop cat'd into SessionStart by
# hand, then the script that replaced it, then the per-turn reminder that came
# with it. Each is matched on its exact command, so a `cat` of something else,
# or anyone else's hook on the same event, is left alone.
RETIRED_LEGACY_CMD="${CC_LEGACY_SKILLS_HOOK_CMD:-cat ~/.claude/skills/unslop/SKILL.md}"
RETIRED_SKILLS_CMD="${CC_SKILLS_HOOK_CMD:-~/.claude/hooks/session-start-skills.sh}"
RETIRED_TURN_CMD="${CC_TURN_HOOK_CMD:-~/.claude/hooks/turn-skill-reminder.sh}"

command -v jq >/dev/null 2>&1 || {
	echo "install-hooks: jq is required" >&2
	exit 1
}

[ -e "$SETTINGS" ] || printf '{}\n' >"$SETTINGS"

tmp="${SETTINGS}.tmp.$$"
trap 'rm -f "$tmp"' EXIT

jq --arg cmd "$CMD" --arg srcsync "$SRCSYNC" --arg legacy "$RETIRED_LEGACY_CMD" \
	--arg skills_cmd "$RETIRED_SKILLS_CMD" --arg turn_cmd "$RETIRED_TURN_CMD" \
	--arg theme "$THEME" '
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
	| ensure("Stop"; $srcsync; "")
	| ensure("SessionEnd"; $srcsync; "")
	| retire("SessionStart"; $legacy)
	| retire("SessionStart"; $skills_cmd)
	# An earlier version of this script put the whole skill on this event too.
	| retire("UserPromptSubmit"; $skills_cmd)
	| retire("UserPromptSubmit"; $turn_cmd)
	# A null here is Claude Code having written the key without a value, which
	# is still not a choice, so it is filled the same as a missing one.
	| if (.theme // null) == null then .theme = $theme else . end
' "$SETTINGS" >"$tmp"

# Replace only once the new content is known to be valid JSON. Truncating the
# user's settings on a jq quirk would be a bad way to find out about it.
jq -e . "$tmp" >/dev/null

mv -f "$tmp" "$SETTINGS"
trap - EXIT

echo "install-hooks: ${CMD} registered in ${SETTINGS}"
echo "install-hooks: theme is $(jq -r '.theme' "$SETTINGS")"
