#!/usr/bin/env bash
# Start Claude in the current directory, continuing the conversation already
# there if there is one.
#
# `claude -c` is what brings a rebuilt session back where you left it, so every
# claude window the sessionizer opens asks for it. But in a directory Claude has
# never seen, `-c` does not fall back to a fresh session: it exits immediately
# with "No conversation found to continue", and the window drops to the bare
# shell behind it. That is the common case for a brand-new session, which is
# precisely the one that has nothing to continue.
#
# Deciding from the exit status instead -- `claude -c || claude` -- cannot tell
# that failure apart from a session you quit with an error, and would answer it
# by opening a fresh Claude on top of the one you just closed. So the question
# is asked up front: Claude keeps one transcript directory per working
# directory, and no transcript in it means nothing to continue.
#
#   claude-continue.sh [claude args...]
set -u

PROJECTS_DIR="${CC_PROJECTS_DIR:-${HOME}/.claude/projects}"

# Claude names a project directory after the absolute path it belongs to, with
# every character outside [A-Za-z0-9] replaced by a dash: /Users/scott/dotfiles
# is stored as -Users-scott-dotfiles. Resolved with `pwd -P` because that is the
# path Claude itself will record -- a process reports its physical directory,
# not the symlinked one you walked in through.
cwd=$(pwd -P)
slug=$(printf '%s' "$cwd" | tr -c 'A-Za-z0-9' '-')

# Empty transcripts are the same as none: a session recorded before it got its
# first turn has nothing for `-c` to resume either. Sub-directories in there are
# Claude's own per-session state, not conversations, hence the `-s` file test.
for transcript in "${PROJECTS_DIR}/${slug}"/*.jsonl; do
	if [ -s "$transcript" ]; then
		exec claude -c "$@"
	fi
done

exec claude "$@"
