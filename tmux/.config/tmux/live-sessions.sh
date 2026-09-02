#!/usr/bin/env bash
# The set of tmux sessions that were open, kept across a reboot.
#
# Nothing tmux writes survives its server, and the server does not survive the
# machine. What is lost with it is not the panes -- sessionizer.sh rebuilds any
# session from its directory in a second -- but the list: which pieces of work
# were open at all. That is the part you cannot reconstruct by remembering
# harder, and it is all this file holds.
#
# Run from the session-created and session-closed hooks, it rewrites the list
# from the live sessions plus whatever is still carried over from before this
# server started.
# Sourced, it offers ls_restorable to the picker and writes nothing.
#
# Two measured facts about tmux shape this, both pinned in tests/:
#
#   A server killed by a signal -- what a reboot delivers -- fires no
#   session-closed hooks at all. Three live sessions, zero hook runs. So a
#   reboot cannot erase the list, and the file left behind names exactly what
#   was open when the machine went down. This is the whole mechanism.
#
#   `tmux kill-server` is the ragged case: it fired the hook once for two
#   sessions. A last write arriving mid-teardown can therefore carry a short
#   list or none, which is why an empty answer is never written. Losing the
#   list at the moment the server dies would defeat the point.
#
# Outliving the reboot turned out to be only half the job, and the missing half
# is why .live-sessions.carry exists. The hooks come back with the next server,
# and the first session opened on it rewrote the file from the live set -- so
# the names the reboot had preserved were gone seconds into the new boot, well
# before anyone could press the key that lists them. They are held in the carry
# file instead, keyed by the pid of the server that last wrote it: a pid that
# has changed means no run has happened on this server yet, and whatever the
# list still holds is what the reboot left. Carried names are written back
# alongside the live set on every run. Reopening one hands it to the live set
# and drops it from the carry, so closing it after that is a real close rather
# than an unfinished restore, and the list cannot grow without end.
#
# The hook strings in tmux.conf must contain no '#'. tmux format-expands a hook
# body before running it, so a '#S' intended for the shell is substituted with
# the hook's own session name first -- which is why they name this script and
# pass nothing.

# Homebrew's tmux, for the same reason sessionizer.sh says so: a hook runs
# under `/bin/sh -c` with whatever environment the server was started in, and
# an inherited PATH is not something to rely on.
export PATH="/opt/homebrew/bin:$PATH"

LS_FILE="${LS_FILE:-$HOME/.config/tmux/.live-sessions}"
LS_DIRS="${LS_DIRS:-$HOME/.config/tmux/.session-dirs}"
LS_TMUX="${LS_TMUX:-tmux}"
# Which names are held over from before this server started, and the server they
# were held over from. First line is the server's pid, the rest are names.
LS_CARRY="${LS_CARRY:-${LS_FILE}.carry}"

# Split so tests can aim the script at a throwaway server with `-L`.
read -ra _ls_tmux <<<"$LS_TMUX"

ls_record() {
	local names
	names=$("${_ls_tmux[@]}" list-sessions -F '#S' 2>/dev/null)

	# See the header: no sessions is what a dying server reports, and it is
	# indistinguishable from the truth. Refusing to write is the safe reading --
	# the cost of keeping a stale list is one dim row in a picker, and the cost
	# of erasing a live one is the work you forgot you had open.
	[ -n "$names" ] || return 0

	local -A live=()
	local name
	while IFS= read -r name; do
		[ -n "$name" ] && live["$name"]=1
	done <<<"$names"

	# What is still held over from before this server, and the pid that wrote
	# it. The header has the why; this is only the reading of it.
	local carried=() id=""
	if [ -r "$LS_CARRY" ]; then
		{
			IFS= read -r id
			while IFS= read -r name; do
				[ -n "$name" ] && carried+=("$name")
			done
		} <"$LS_CARRY"
	fi

	# A server pid that is not the one the carried names were written under
	# means this is the first run since the machine came back, and whatever the
	# list still holds is what the reboot left. Reading it here is what makes
	# the carry survive: after this the live set is free to be rewritten.
	local server
	server=$("${_ls_tmux[@]}" display-message -p '#{pid}' 2>/dev/null)
	if [ -n "$server" ] && [ "$id" != "$server" ]; then
		carried=()
		if [ -r "$LS_FILE" ]; then
			while IFS= read -r name; do
				[ -n "$name" ] && carried+=("$name")
			done <"$LS_FILE"
		fi
	fi

	# Reopening a carried session hands it back to the live set, and it leaves
	# the carry for good. Closing it after that is a real close rather than an
	# unfinished restore, which is what stops the list growing without end.
	local kept=()
	for name in ${carried[@]+"${carried[@]}"}; do
		[ -z "${live[$name]:-}" ] && kept+=("$name")
	done

	# A scratch file per run, not one shared name. session-created and
	# session-closed fire close enough together to overlap -- a sessionizer
	# switch that rebuilds one session while closing another does it -- and two
	# runs sharing a scratch file means the second mv finds nothing there,
	# because the first already moved it away. The rename is atomic either way,
	# so whichever run lands last wins, and it is the one holding the freshest
	# list.
	local tmp="${LS_FILE}.tmp.$$"
	{
		printf '%s\n' "$names"
		if [ ${#kept[@]} -gt 0 ]; then printf '%s\n' "${kept[@]}"; fi
	} >"$tmp" && mv "$tmp" "$LS_FILE" || rm -f "$tmp"

	local ctmp="${LS_CARRY}.new.$$"
	{
		printf '%s\n' "$server"
		if [ ${#kept[@]} -gt 0 ]; then printf '%s\n' "${kept[@]}"; fi
	} >"$ctmp" && mv "$ctmp" "$LS_CARRY" || rm -f "$ctmp"
}

# Recorded sessions that are not currently running, in recorded order. The live
# ones are passed in by the caller, which already has the list.
ls_restorable() {
	[ -r "$LS_FILE" ] || return 0

	local -A live=() dirs=()
	local name

	for name in "$@"; do live["$name"]=1; done

	# One pass over .session-dirs rather than a lookup per row. The file runs to
	# a few hundred lines and this is on the path of the most-pressed key in the
	# config; sessionizer.sh has the long version of why a process per row is
	# the thing to avoid here.
	local dir
	while IFS=$'\t' read -r name dir; do
		[ -n "$name" ] && dirs["$name"]="$dir"
	done <"$LS_DIRS" 2>/dev/null

	while IFS= read -r name; do
		[ -n "$name" ] || continue
		[ -z "${live[$name]:-}" ] || continue

		# A session whose directory has been removed since -- a worktree cleaned
		# up while the machine was off -- is dropped rather than offered.
		# Rebuilding it would fall back to $HOME and leave a session named for a
		# branch sitting in your home directory, which reads as a live piece of
		# work and is not one.
		dir="${dirs[$name]:-}"
		[ -n "$dir" ] && [ -d "$dir" ] || continue

		printf '%s\n' "$name"
	done <"$LS_FILE"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	ls_record
fi
