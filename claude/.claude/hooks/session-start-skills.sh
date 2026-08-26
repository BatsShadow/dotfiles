#!/usr/bin/env bash
# Print the skills that apply to every session, for SessionStart to inject.
#
# A skill reaches Claude only when something loads it, and the load that never
# happens on its own is the one for a skill meant to be in force before the
# first word: unslop governs whatever gets written, so waiting for a trigger
# means the first answer is already written wrong.
#
# This exists rather than a `cat` written straight into settings.json because
# settings.json is deliberately not stowed -- see install-hooks.sh. A command
# spelled out there is a per-machine edit no checkout records, and a second
# always-on skill would mean editing every machine by hand. Pointing the
# registration at this file puts the decision back in the repo.
#
# stdout becomes session context, so everything printed here is spent tokens on
# every session, clear and compact. Keep the list short.
#
#   session-start-skills.sh
set -u

SKILLS_DIR="${CC_SKILLS_DIR:-${HOME}/.claude/skills}"

# Named, not detected. Each of these declares that it always applies in its own
# description, but reading that back out of the frontmatter would go quiet the
# moment the wording drifted, and a session that has silently stopped unslopping
# looks exactly like one that never needed to.
ALWAYS_ON="unslop"

for skill in $ALWAYS_ON; do
	f="${SKILLS_DIR}/${skill}/SKILL.md"
	# A half-stowed machine is not worth failing a session start over. The skill
	# is missing either way, and a non-zero exit would put a hook error on top
	# of it.
	[ -r "$f" ] && cat "$f"
done

exit 0
