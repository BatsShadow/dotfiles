#!/usr/bin/env bash
# Remove git worktrees, and the tmux sessions sitting in them. Tab to check
# several, Enter to remove them.
#
# Shows work with nothing left to lose, by default: branches already landed on
# upstream/main, plus branches with no commits at all, in both cases clean and
# with no Claude running. ctrl-a widens to everything, with a reason against each
# row that was held back. Of the 103 worktrees on the machine this was written
# for, 35 had landed and 21 had never been committed to, so the default view is
# the difference between a cleanup and an afternoon.
#
# Landed and empty are not the same fact and do not render the same. A landed
# branch gets the tick; an empty one gets no mark and says "no unmerged commits"
# instead, because the reason it is safe to remove is that there is nothing in
# it -- which is also a fair description of work you started ten minutes ago.
#
# Merged-ness is not `git branch --merged`; main is squash-merged, and that test
# cannot see a squashed branch at all. See merged-branches.sh, which also
# explains why an empty branch and a dirty one each have to be excluded
# explicitly. The answer is cached because computing it costs ~7s.
#
# Nothing here passes --force. `git worktree remove` refusing a dirty tree is
# the backstop under the dirty check above, not a substitute for it: the check
# keeps the row out of the list, and the refusal catches the minute of staleness
# the cache allows. Anything that does get skipped is named individually at the
# end, and forcing stays a single-worktree decision made deliberately.

export PATH="/opt/homebrew/bin:$PATH"

REPO_DIR="${CC_MERGED_REPO:-$HOME/src/upngo/upngo-web}"
WORKTREE_DIR="${CC_MERGED_WORKTREES:-$HOME/src/upngo/worktrees}"

# Branch state fills the glyph column here. A waiting or busy Claude still wins
# it, but an idle one is not worth showing: any Claude at all already holds the
# row out of the default list, so the only thing left to tell you about a row
# you can see is whether its work has landed.
export CC_FALLBACK=merged

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

		# What keeps a row out of the default list, and what merely annotates
		# one that is in it, are different things. `not merged` is the first;
		# `no commits yet` is the second -- it explains an absent tick on a row
		# that is offered anyway.
		reason="" note=""
		case "${CC_MERGED[$name]:-}" in
		merged) ;;
		# Not "no commits yet": the same state covers a branch merged with
		# --no-ff, whose commits very much exist and are all on main. See
		# merged-branches.sh.
		empty) note="no unmerged commits" ;;
		# Uncommitted work has landed nowhere, whatever the commits say, so it
		# counts as not merged and outranks both states above. It is also the
		# one reason here that `git worktree remove` would have caught anyway --
		# stated up front so the row never gets offered rather than failing at
		# the end of a bulk removal.
		dirty) reason="uncommitted changes" ;;
		*) reason="not merged" ;;
		esac

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
			cc_row "$name" dir "${note:+${note}, }${reason}"
		else
			cc_row "$name" session "$note"
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
			--header="nothing left to lose · ctrl-a for all" \
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
