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
# That ambiguity is what the age on every row is for: "no unmerged commits, 5min
# ago" and "no unmerged commits, 37d ago" are the same state and opposite
# decisions, and nothing else on the row separates them.
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
#
# The removals themselves do not run here. A popup holds its whole tmux client
# hostage while it is open, and deleting a worktree carrying node_modules is
# tens of thousands of files -- long enough, several rows deep, to be the only
# part of this that ever feels slow. So the popup's job ends at the y/N: it
# hands the list to the tmux server and exits, the client comes straight back,
# and the deleting happens with nobody watching. What that costs is the running
# commentary, which nothing was reading anyway; the log keeps it, and the status
# line and a notification both get told when it is done -- the second because
# "with nobody watching" often means the terminal is not on screen at all.

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
	# The arrays have to be declared even though nothing will fill them. An
	# undeclared name subscripted with a string is an INDEXED array to bash, so
	# `${CC_RANK[$name]:-0}` evaluates the branch name as an arithmetic
	# expression -- and a name like `device-name-fixes` recurses until bash
	# gives up, once per row. Degrading is supposed to cost the marks, not the
	# listing.
	declare -A CC_RANK=()
	declare -A CC_MERGED=()
	declare -A CC_DIRTY_AT=()
	cc_load() { :; }
	cc_merged_load() { :; }
	cc_row() { printf '%s\t%s\n' "$1" "$1"; }
fi

current_session=""
[[ -n "${TMUX:-}" ]] && current_session=$(tmux display-message -p '#S')

# When each worktree was last touched: the newest uncommitted change if it has
# one, otherwise the tip of its branch. Two sources because the two facts cost
# wildly different amounts. Commit times come out of one `for-each-ref` over the
# whole repo -- 525 branches in 29ms, cheaper than caching would be -- while the
# working-tree side needs a stat per changed file and so rides along with the
# dirty sweep, which already knows which files those are.
#
# Uncommitted wins for the same reason it wins the state column: a tree edited
# five minutes ago is not thirty-seven days old just because nobody committed.
now=$(date +%s)

age_of() {
	local then="$1" secs
	[[ -n "$then" ]] || return 0
	secs=$((now - then))
	((secs < 0)) && secs=0

	# One significant figure and never two units. This sits in front of the
	# reason a row was held back, and the row is being scanned rather than read.
	if ((secs < 60)); then printf 'just now'
	elif ((secs < 3600)); then printf '%dmin ago' "$((secs / 60))"
	elif ((secs < 86400)); then printf '%dh ago' "$((secs / 3600))"
	else printf '%dd ago' "$((secs / 86400))"
	fi
}

# Re-entered by fzf's reload binding, which is why listing is a mode of this
# script rather than a function the main path calls.
if [[ "${1:-}" == "--list" ]]; then
	cc_load
	cc_merged_load

	show_all=0
	[[ "${2:-}" == "all" ]] && show_all=1

	# Every branch in the repo, not just the ones with worktrees. Filtering would
	# cost more than the surplus entries do -- this is one process either way.
	declare -A tip_at=()
	while IFS=$'\t' read -r ref when; do
		[[ -n "$ref" ]] && tip_at["$ref"]="$when"
	done < <(git -C "$REPO_DIR" for-each-ref \
		--format='%(refname:short)%09%(committerdate:unix)' \
		refs/heads/ 2>/dev/null)

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

		# Age leads, because it is the one thing every row has and the only
		# part of the suffix with a constant shape -- the eye can run down the
		# column even though the names in front of it are ragged.
		when="${CC_DIRTY_AT[$name]:-}"
		if [[ -z "$when" ]]; then
			when="${tip_at[$name]:-}"

			# Not every worktree here belongs to REPO_DIR. The android repo
			# keeps its worktrees in the same directory, and a detached HEAD
			# has no branch to be listed under at all -- neither appears in the
			# bulk map. Ask those directly: it is one git call each and there
			# were four of them against 103 rows, which is still two orders of
			# magnitude cheaper than asking every worktree individually.
			[[ -n "$when" ]] || when=$(git -C "$dir" log -1 --format=%ct 2>/dev/null)
		fi
		detail="$(age_of "$when")"
		[[ -n "$note" ]] && detail="${detail:+${detail}, }${note}"
		[[ -n "$reason" ]] && detail="${detail:+${detail}, }${reason}"

		# The branch name, not the path: it is what the row is about, what the
		# tmux session is called, and short enough to read at a glance. The
		# path is rebuilt from it below -- every one of these lives directly
		# under WORKTREE_DIR by construction.
		# Held back rows appear only in the wide view, and carry why. A hidden
		# row with no explanation is indistinguishable from a bug. Decided
		# before anything is printed, so a skipped row cannot leave a sort key
		# behind for the next one to inherit.
		if [[ -n "$reason" ]] && ((!show_all)); then
			continue
		fi

		# Sort key, stripped again below. It has to travel with the row rather
		# than be re-derived, because by this point the age has been rounded to
		# a word and half the rows would tie on "94d ago".
		#
		# A row whose age could not be established sorts as though it were
		# ancient, which under the order below puts it last. That is the same
		# placement it had when the list ran oldest-first and the key defaulted
		# the other way: unknown belongs at the bottom whichever end is the
		# interesting one, because it is the row you can say least about.
		printf '%s\t' "${when:-0}"

		# The branch name, not the path: it is what the row is about, what the
		# tmux session is called, and short enough to read at a glance. The
		# path is rebuilt from it below -- every one of these lives directly
		# under WORKTREE_DIR by construction.
		if [[ -n "$reason" ]]; then
			cc_row "$name" dir "$detail"
		else
			cc_row "$name" session "$detail"
		fi
		# Newest first, which is the opposite of `x` and deliberately so. The
		# two lists are read differently: a stale tmux session is safe because
		# it is stale, and nothing else about it needs recalling, so oldest at
		# the top is exactly right there. Deleting a worktree is a judgement,
		# and judgement needs context -- you can still say what you were doing
		# in the branch you touched last week, while a name from four months
		# ago tells you nothing and the row cannot supply the rest.
		#
		# Age is still the first thing on every row, so the old end remains
		# easy to find. It is just no longer where the list starts.
	done | sort -t$'\t' -k1,1nr | cut -f2-
	exit 0
fi

self="${BASH_SOURCE[0]}"
# The background half is re-entered by the tmux server, whose working directory
# is not this one and is not knowable from here.
[[ "$self" == /* ]] || self="$PWD/$self"

LOG="${TMPDIR:-/tmp}/worktree-remove.log"

# The removals, wherever they end up running. One line per worktree, and the
# ones git refused left in `failed`.
remove_selected() {
	local branch dir
	failed=()

	for branch in "$@"; do
		dir="${WORKTREE_DIR}/${branch}"

		if git -C "$REPO_DIR" worktree remove "$dir" 2>/dev/null; then
			printf '    removed  %s\n' "$branch"
			if tmux has-session -t="$branch" 2>/dev/null; then
				tmux kill-session -t "$branch" 2>/dev/null &&
					printf '    killed   %s (session)\n' "$branch"
			fi
		else
			# Almost always uncommitted changes, which is the case worth
			# stopping for. Named individually so it can be dealt with on its
			# own terms.
			printf '    SKIPPED  %s -- not clean\n' "$branch"
			failed+=("$branch")
		fi
	done
}

force_hint() {
	printf '\n  %d skipped for local changes. Inspect before forcing:\n\n' "${#failed[@]}"
	printf '    git -C %s worktree remove --force %s/<name>\n' "$REPO_DIR" "$WORKTREE_DIR"
}

# terminal-notifier first, then osascript, which is the order and the reasoning
# in tmux-powerline/segments/claude/notify.sh. That one is not reusable from
# here: it is shaped around the click action that jumps you to the waiting
# session, and the sessions this script notifies about have just been killed.
# So no -execute, and with nothing to click, the two backends differ only in
# which of them is installed.
#
# Both drop the notification silently when notifications are switched off for
# them in System Settings, and both still exit 0. The status line carries the
# same summary for that reason -- this is the copy you get when you have looked
# away from tmux, not the only one.
notify() {
	local title="worktree cleanup" message="$1"

	if command -v terminal-notifier >/dev/null 2>&1; then
		# -group so a second run replaces the first card instead of stacking.
		# Nothing needs quoting: these are separate argv, and without -execute
		# there is no shell on the far side to reach.
		terminal-notifier -title "$title" -message "$message" \
			-group worktree-remove >/dev/null 2>&1
		return 0
	fi

	# Here there is. The message reaches osascript as an AppleScript string
	# literal, and it carries branch names, so a double quote in one would end
	# that literal early. Backslashes have to be escaped before quotes -- doing
	# it the other way round plants backslashes for the backslash pass to double
	# up. The title is a constant and needs none of this.
	message="${message//\\/\\\\}"
	message="${message//\"/\\\"}"
	osascript -e "display notification \"${message}\" with title \"${title}\"" >/dev/null 2>&1
}

# Re-entered through `tmux run-shell -b`, with the popup that asked already
# gone. The branches arrive in a file rather than as arguments because
# run-shell expands its command as a FORMAT before /bin/sh ever sees it, and a
# `#` is legal in a branch name -- one `#{` in the list and the command comes
# out the other side rewritten. A path we generate cannot carry one.
if [[ "${1:-}" == "--remove" ]]; then
	mapfile -t selected <"$2"
	rm -f "$2"
	((${#selected[@]})) || exit 0

	# So the popup vanishing is distinguishable from having answered N. Long
	# enough to survive the popup tearing down over the top of it; the default
	# display-time is 750ms and this is racing a screen redraw.
	tmux display-message -d 2000 -l "removing ${#selected[@]} worktree(s)..."

	# `failed` survives this because a redirected group is not a subshell.
	{
		printf '\n=== %s ===\n' "$(date '+%F %T')"
		remove_selected "${selected[@]}"
	} >>"$LOG" 2>&1

	removed=$((${#selected[@]} - ${#failed[@]}))
	if ((${#failed[@]})); then
		force_hint >>"$LOG"

		# Six seconds, not the zero-delay hold this used to take. A message with
		# no delay stays up until a key is pressed and swallows that keystroke,
		# which was worth it while the status line was the only place this could
		# land; the notification now sits in Notification Center until dismissed,
		# so the outcome that needs a decision no longer depends on catching a
		# status line at the right moment.
		summary="removed ${removed}, skipped ${#failed[@]} for local changes: ${failed[*]}"
		tmux display-message -d 6000 -l "${summary} -- see $LOG"
	else
		summary="removed ${removed} worktree(s)"
		tmux display-message -d 4000 -l "$summary"
	fi

	notify "$summary"
	exit 0
fi

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

# Hand off and get out of the way. run-shell hangs the work off the tmux
# server, which outlives this popup by definition -- backgrounding it here
# would only outlive the popup by however long tmux takes to tear the pty down.
if [[ -n "${TMUX:-}" ]]; then
	list=$(mktemp "${TMPDIR:-/tmp}/worktree-remove.XXXXXX")
	printf '%s\n' "${selected[@]}" >"$list"
	tmux run-shell -b "'$self' --remove '$list'"
	exit 0
fi

# Run from a plain shell instead, where there is no server to hand to and
# nothing being blocked by staying.
printf '\n'
remove_selected "${selected[@]}"
((${#failed[@]})) && force_hint
printf '\n'
