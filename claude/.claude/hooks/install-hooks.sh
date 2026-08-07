#!/usr/bin/env bash
# Register claude-waiting.sh in ~/.claude/settings.json.
#
# settings.json is deliberately NOT stowed. Claude Code writes to it itself --
# /permissions, plugin toggles, model choice -- and a program that saves by
# writing a temp file and renaming it over the target would replace the symlink
# with a regular file. The package would look installed, and would silently
# stop tracking. So the scripts are stowed and the reference to them is merged
# in here instead.
#
# Idempotent, and additive per event: an entry is appended only when no existing
# one already runs this command, so hooks configured for other purposes survive.
#
#   ./install-hooks.sh [settings.json]

set -eu

SETTINGS="${1:-${HOME}/.claude/settings.json}"
CMD="${CC_HOOK_CMD:-~/.claude/hooks/claude-waiting.sh}"

command -v jq >/dev/null 2>&1 || {
	echo "install-hooks: jq is required" >&2
	exit 1
}

[ -e "$SETTINGS" ] || printf '{}\n' >"$SETTINGS"

tmp="${SETTINGS}.tmp.$$"
trap 'rm -f "$tmp"' EXIT

jq --arg cmd "$CMD" '
	def ensure($ev):
		.hooks[$ev] = (
			(.hooks[$ev] // [])
			| if any(.[]; (.hooks // []) | any(.command == $cmd))
			  then .
			  else . + [{hooks: [{type: "command", command: $cmd}]}]
			  end
		);

	(.hooks //= {})
	| ensure("Stop")
	| ensure("Notification")
	| ensure("UserPromptSubmit")
	| ensure("SessionEnd")
' "$SETTINGS" >"$tmp"

# Replace only once the new content is known to be valid JSON. Truncating the
# user's settings on a jq quirk would be a bad way to find out about it.
jq -e . "$tmp" >/dev/null

mv -f "$tmp" "$SETTINGS"
trap - EXIT

echo "install-hooks: ${CMD} registered in ${SETTINGS}"
