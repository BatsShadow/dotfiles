#!/usr/bin/env bash
# Carries repos, worktrees and uncommitted work between two machines through
# GitHub. DESIGN.md has the why.
#
#   srcsync.sh publish [path]   snapshot what changed here and push it, or
#                               just path's repo
#   srcsync.sh apply [path]     take what changed on the other machine, or
#                               just path's worktree
#   srcsync.sh sync             publish, then apply
#   srcsync.sh status           last sync, unpushed repos, conflicts
#   srcsync.sh conflicts        one line per conflict
#   srcsync.sh resolve <path> theirs|mine  settle one
#   srcsync.sh pick             choose a side in fzf
#   srcsync.sh auto <event> [path]  what every trigger calls; off, it only
#                               logs what it would run
set -u

LIB=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib
. "$LIB/common.sh"
. "$LIB/snapshot.sh"
. "$LIB/transcripts.sh"
. "$LIB/restart.sh"
. "$LIB/publish.sh"
. "$LIB/apply.sh"
. "$LIB/auto.sh"
. "$LIB/resolve.sh"
. "$LIB/maintain.sh"

cmd_status() {
	local at
	at=$(cat "$LAST_SUCCESS" 2>/dev/null) || at=never
	echo "last sync: $at"
	[ -s "$PENDING" ] && echo "unpushed: $(tr '\n' ' ' <"$PENDING")"
	[ -f "$CONFLICTS" ] && jq -r '.[] | "conflict: \(.worktree) (\(.host))"' "$CONFLICTS"
	return 0
}

load_config
case ${1:-} in
publish | apply | sync | resolve)
	take_lock || {
		say "another run holds the lock"
		exit 0
	}
	;;
esac
scoped=
if { [ "${1:-}" = publish ] || [ "${1:-}" = apply ]; } && [ -n "${2:-}" ]; then
	scoped=$(resolve_path "$2") || {
		say "$2: not a synced repo"
		exit 0
	}
fi

case ${1:-} in
publish)
	if [ -n "$scoped" ]; then cmd_publish "${scoped%%$'\t'*}"; else cmd_publish; fi
	;;
apply)
	if [ -n "$scoped" ]; then cmd_apply "${scoped#*$'\t'}"; else cmd_apply; fi
	;;
sync)
	cmd_publish
	cmd_apply
	;;
status) cmd_status ;;
auto) cmd_auto "${2:-}" "${3:-}" ;;
conflicts) cmd_conflicts ;;
resolve) cmd_resolve "${2:-}" "${3:-}" ;;
pick) cmd_pick ;;
*)
	echo "usage: srcsync.sh publish|apply|sync|status|auto|conflicts|resolve|pick" >&2
	exit 2
	;;
esac
