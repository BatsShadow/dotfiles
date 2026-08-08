#!/usr/bin/env bash
# Remove git worktrees, and the tmux sessions sitting in them. Tab to check
# several, Enter to remove them.
#
# Shows only finished work by default: branches already landed on upstream/main
# with no Claude running in them. ctrl-a widens the list to everything, with a
# reason against each row that was held back. There were 103 worktrees and 71
# landed branches on the machine this was written for, so the default view is
# the difference between a cleanup and an afternoon.
#
# Merged-ness is not `git branch --merged` -- main is squash-merged, and that
# test misses squashed branches entirely (31 of 71 here). See
# merged-branches.sh; the answer is cached because computing it costs ~5s.
#
# What is deliberately NOT checked up front: whether a worktree has uncommitted
# changes. That is ~0.3s per worktree, so ~32s across this many, which is not a
# price a popup can pay. It does not need to -- `git worktree remove` refuses a
# dirty worktree on its own, and this never passes --force in bulk. So a dirty
# worktree fails loudly, individually, and is reported back rather than being
# quietly destroyed. Force removal stays a single-worktree decision.

export PATH="/opt/homebrew/bin:$PATH"

REPO_DIR="${CC_MERGED_REPO:-$HOME/src/upngo/upngo-web}"
WORKTREE_DIR="${CC_MERGED_WORKTREES:-$HOME/src/upngo/worktrees}"

# Idle Claudes are marked here: an unmarked row has to mean "nothing running in
# there", since that is exactly what is being asked before removal.
export CC_SHOW_IDLE=1

HERE="${BASH_SOURCE[0]%/*}"
CC_HELPER="${HERE}/claude-status.sh"
if [[ -r "$CC_HELPER" ]]; then
	# shellcheck source=claude-status.sh
	source "$CC_HELPER"
else
	cc_load() { :; }
	cc_merged_load() { :; }
	cc_row() { printf '%s\t%s\n' "$1" "$1"; }
fi

current_session=""
[[ -n "${TMUX:-}" ]] && current_session=$(tmux display-message -p '#S')

# Re-entered by fzf's reload binding, which is why listing is a mode of this
# script rather than a function the main path calls.
if [[ "${1:-}" == "--list" ]]; then
	cc_load
	cc_merged_load

	show_all=0
	[[ "${2:-}" == "all" ]] && show_all=1

	for dir in "$WORKTREE_DIR"/*/; do
		[[ -d "$dir" ]] || continue
		dir="${dir%/}"
		name="${dir##*/}"

		[[ "$name" == "$current_session" ]] && continue

		reason=""
		[[ -z "${CC_MERGED[$name]:-}" ]] && reason="not merged"
		if [[ "${CC_RANK[$name]:-0}" -gt 1 ]]; then
			reason="${reason:+${reason}, }claude active"
		fi

		# The branch name, not the path: it is what the row is about, what the
		# tmux session is called, and short enough to read at a glance. The
		# path is rebuilt from it below -- every one of these lives directly
		# under WORKTREE_DIR by construction.
		if [[ -n "$reason" ]]; then
			# Held back rows appear only in the wide view, and carry why. A
			# hidden row with no explanation is indistinguishable from a bug.
			((show_all)) || continue
			cc_row "$name" dir "$reason"
		else
			cc_row "$name" session
		fi
	done
	exit 0
fi

self="${BASH_SOURCE[0]}"

mapfile -t selected < <(
	"$self" --list |
		fzf --ansi --multi \
			--delimiter='\t' --with-nth=1 --accept-nth=2 \
			--ghost="tab to check, enter to remove" \
			--prompt="remove worktree> " \
			--header="merged + no claude · ctrl-a for all" \
			--bind "ctrl-a:change-header(everything · held-back rows say why)+reload($self --list all)"
)

((${#selected[@]})) || exit 0

printf '\n  removing %d worktree(s):\n\n' "${#selected[@]}"
printf '    %s\n' "${selected[@]}"
printf '\n'

read -rp "  proceed? (y/N) " confirm
[[ "$confirm" == "y" || "$confirm" == "Y" ]] || exit 0
printf '\n'

failed=()
for branch in "${selected[@]}"; do
	dir="${WORKTREE_DIR}/${branch}"

	if git -C "$REPO_DIR" worktree remove "$dir" 2>/dev/null; then
		printf '    removed  %s\n' "$branch"
		if tmux has-session -t="$branch" 2>/dev/null; then
			tmux kill-session -t "$branch" 2>/dev/null &&
				printf '    killed   %s (session)\n' "$branch"
		fi
	else
		# Almost always uncommitted changes, which is the case worth stopping
		# for. Named individually so it can be dealt with on its own terms.
		printf '    SKIPPED  %s -- not clean\n' "$branch"
		failed+=("$branch")
	fi
done

if ((${#failed[@]})); then
	printf '\n  %d skipped for local changes. Inspect before forcing:\n\n' "${#failed[@]}"
	printf '    git -C %s worktree remove --force %s/<name>\n' "$REPO_DIR" "$WORKTREE_DIR"
fi

printf '\n'
read -rp "  press enter to continue..."
