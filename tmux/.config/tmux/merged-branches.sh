#!/usr/bin/env bash
# Which worktree branches have already landed on upstream/main.
#
# main is squash-merged, so a landed branch shares no commit with main and is
# never an ancestor of it. `git branch --merged` cannot see one.
#
# The test that does: collapse the branch to a single commit carrying its tree,
# on top of its merge base, then ask `git cherry` whether that patch is already
# upstream. A squash commit's diff is exactly the branch's diff against the
# merge base, so the patch-ids match. Measured against `gh pr list --state
# merged` over 103 worktrees this found 40 with no false positives -- the same
# answer GitHub gives, without the round trip. What it misses is PRs whose
# conflicts were resolved during the merge, which changes the patch and is not
# recoverable locally at any price.
#
# Two traps, both of which this got wrong first time round and both of which
# report unstarted work as finished:
#
#   An empty patch matches everything. A worktree branched off main and not yet
#   committed to has a tree identical to its merge base, so its collapsed patch
#   is empty and `git cherry` calls it upstream. 30 of 103 worktrees here are
#   in exactly that state, including main itself. They are reported as `empty`,
#   which is a different fact from merged and nearly its opposite.
#
#   `empty` also swallows the conventionally merged branch, because an ancestor
#   of main has an empty patch for the same structural reason. Both are `empty`
#   and nothing here can separate them, so the state means "has no commits that
#   are not already on main" -- true of a branch you just created and of one
#   merged with --no-ff, and the reason callers must not word it as "no commits
#   yet". It costs nothing in this repo, where main is squash-merged and the
#   --no-ff case does not arise, and either way both are equally safe to remove.
#
#   `git branch --merged` cannot help. If a branch is an ancestor of main then
#   the merge base IS the branch tip, so its diff against that base is empty by
#   definition -- the ancestor test can only ever fire on the branches above.
#   It fired on 55 here and contributed no genuine detection at all. Adding it
#   as a second opinion took the count from 40 to 70, all 30 of them wrong.
#
# Uncommitted changes outrank both. Work in the working tree has landed nowhere
# by definition, so a dirty worktree is reported as `dirty` whatever its commits
# say -- 14 of the 70 branches this would otherwise offer up as reclaimable have
# changes sitting in them. An empty branch with uncommitted work is the worst
# row a delete list can contain: nothing committed, so it looks untouched, and
# everything in it unsaved.
#
# Output is one `<state>\t<branch>` line per worktree branch that is not simply
# outstanding work, where state is `dirty`, `merged` or `empty`.
#
# Two caches, because the two questions decay at completely different rates.
# Whether a branch landed changes when someone merges a PR and a worktree you
# finished with never becomes unfinished, so 15 minutes stale costs one extra
# row. Whether a tree is dirty changes the moment you save a file, so it gets a
# minute. They are computed and stored separately and joined on read.
#
# Both are cached rather than computed on demand because these run inside popups
# that must open instantly: the branch pass is ~5s over 103 worktrees and the
# dirty pass is ~1.6s even fully parallel and warm. Readers get whatever the
# caches hold and never block.
#
#   merged-branches.sh                  print the joined set, refreshing behind you
#   merged-branches.sh --refresh        recompute both now, synchronously
#   merged-branches.sh --refresh-dirty  recompute just the dirty set
#   merged-branches.sh --stamp          print both caches' ages and the base ref

set -u

REPO_DIR="${CC_MERGED_REPO:-$HOME/src/upngo/upngo-web}"
WORKTREE_DIR="${CC_MERGED_WORKTREES:-$HOME/src/upngo/worktrees}"
BASE_REF="${CC_MERGED_BASE:-upstream/main}"
CACHE_DIR="${CC_MERGED_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/tmux-claude}"
CACHE="${CACHE_DIR}/merged-branches"
STAMP="${CACHE_DIR}/merged-branches.stamp"
DIRTY="${CACHE_DIR}/merged-branches.dirty"
DIRTY_STAMP="${CACHE_DIR}/merged-branches.dirty.stamp"

# How long each cached answer stays good. See the header for why they differ by
# an order of magnitude.
TTL="${CC_MERGED_TTL:-900}"
DIRTY_TTL="${CC_MERGED_DIRTY_TTL:-60}"

# One `git status` per worktree, and the whole reason this needs a cache at all.
# Parallel because they are independent and each is mostly waiting on the disk.
DIRTY_JOBS="${CC_MERGED_DIRTY_JOBS:-12}"

# merged | empty | (nothing, meaning outstanding work) for one branch.
__mb_state() {
	local branch="$1" mb tree base_tree synthetic

	mb=$(git -C "$REPO_DIR" merge-base "$BASE_REF" "$branch" 2>/dev/null) || return 0
	[ -n "$mb" ] || return 0

	tree=$(git -C "$REPO_DIR" rev-parse "${branch}^{tree}" 2>/dev/null) || return 0
	base_tree=$(git -C "$REPO_DIR" rev-parse "${mb}^{tree}" 2>/dev/null) || return 0

	# Nothing of its own. Must be answered before the patch test rather than by
	# it: an empty patch is trivially already upstream, so `git cherry` would
	# call every untouched worktree merged. See the header.
	if [ "$tree" = "$base_tree" ]; then
		printf 'empty\n'
		return 0
	fi

	synthetic=$(git -C "$REPO_DIR" commit-tree "$tree" -p "$mb" -m merged-probe 2>/dev/null) || return 0

	# `-` prefixes a commit whose patch is already upstream. Anything else,
	# including no output at all, means it is not.
	if git -C "$REPO_DIR" cherry "$BASE_REF" "$synthetic" 2>/dev/null | grep -q '^-'; then
		printf 'merged\n'
	fi
}

__mb_compute() {
	local branch state

	git -C "$REPO_DIR" rev-parse --verify --quiet "$BASE_REF" >/dev/null 2>&1 || return 1

	for dir in "$WORKTREE_DIR"/*/; do
		[ -d "$dir" ] || continue
		branch="${dir%/}"
		branch="${branch##*/}"

		git -C "$REPO_DIR" show-ref --verify --quiet "refs/heads/${branch}" || continue

		# The trunk is not work in progress and is never finished with. Left
		# unclassified it reads as `empty`, perfectly accurately -- it has no
		# commits of its own -- and lands at the top of a list offering to
		# delete it.
		[ "$branch" = "${BASE_REF##*/}" ] && continue

		state=$(__mb_state "$branch")
		[ -n "$state" ] && printf '%s\t%s\n' "$state" "$branch"
	done

	# Explicit, because otherwise the function returns the status of the last
	# branch tested -- so a run ending on an unmerged branch would report
	# failure, and the caller would throw away a perfectly good result.
	return 0
}

# Every worktree with anything uncommitted in it, one branch name per line.
# Untracked files count: `git worktree remove` refuses over them too, so leaving
# them out would put rows in the list that cannot actually be removed.
__mb_compute_dirty() {
	[ -d "$WORKTREE_DIR" ] || return 1

	# `if` rather than `&&` so the child always exits 0. Under `&&` a clean
	# worktree is a non-zero exit, and enough of those make xargs give up and
	# return 123 -- which __mb_refresh_dirty would read as "the sweep failed"
	# and discard a complete, correct result.
	find "$WORKTREE_DIR" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null |
		xargs -0 -P "$DIRTY_JOBS" -n1 sh -c '
			if [ -n "$(git -C "$1" status --porcelain 2>/dev/null)" ]; then
				basename "$1"
			fi
		' _
}

# Written whole and renamed into place. A reader that catches a half-written
# cache would silently drop marks from rows that have them, which is a worse
# failure than being a few minutes stale.
__mb_write() {
	local dest="$1" tmp="${1}.tmp.$$"
	if "$2" >"$tmp" 2>/dev/null; then
		mv -f "$tmp" "$dest"
	else
		rm -f "$tmp"
		return 1
	fi
}

__mb_refresh() {
	mkdir -p "$CACHE_DIR" 2>/dev/null || return 1
	__mb_write "$CACHE" __mb_compute || return 1
	printf '%s\n%s\n' \
		"$(date +%s)" \
		"$(git -C "$REPO_DIR" rev-parse --short "$BASE_REF" 2>/dev/null)" >"$STAMP"
}

__mb_refresh_dirty() {
	mkdir -p "$CACHE_DIR" 2>/dev/null || return 1
	__mb_write "$DIRTY" __mb_compute_dirty || return 1
	date +%s >"$DIRTY_STAMP"
}

__mb_stale() {
	[ -f "$CACHE" ] || return 0
	[ -f "$STAMP" ] || return 0

	local when base_now base_then
	when=$(head -1 "$STAMP" 2>/dev/null)
	[ -n "$when" ] || return 0
	[ "$(($(date +%s) - when))" -ge "$TTL" ] && return 0

	# The base moving is what actually changes the answer, so a cache built
	# against a different upstream/main is stale however recently it was built.
	base_then=$(sed -n 2p "$STAMP" 2>/dev/null)
	base_now=$(git -C "$REPO_DIR" rev-parse --short "$BASE_REF" 2>/dev/null)
	[ "$base_then" = "$base_now" ] || return 0

	return 1
}

__mb_dirty_stale() {
	[ -f "$DIRTY" ] || return 0
	[ -f "$DIRTY_STAMP" ] || return 0

	local when
	when=$(head -1 "$DIRTY_STAMP" 2>/dev/null)
	[ -n "$when" ] || return 0
	[ "$(($(date +%s) - when))" -ge "$DIRTY_TTL" ]
}

# Join the two caches. Dirty wins: uncommitted work has landed nowhere, so it
# overrides whatever the branch's commits say. A dirty branch the branch pass
# never classified still gets a line, because "uncommitted changes" is a better
# reason to hold a row back than the silence that would otherwise stand in.
__mb_join() {
	[ -f "$CACHE" ] || return 0

	# No dirty pass yet -- serve the branch states alone rather than nothing.
	# Marks then risk being optimistic for one refresh cycle, which is the same
	# risk the TTL already carries and is caught by `git worktree remove`.
	if [ ! -f "$DIRTY" ]; then
		cat "$CACHE"
		return 0
	fi

	# Keyed on FILENAME rather than the usual `NR == FNR`, which is wrong here
	# in the one case that matters most. When nothing is dirty the first file is
	# empty, so awk reads no record from it and NR == FNR is still true on the
	# first line of the second -- every branch would be filed as dirty and come
	# back out marked dirty. It misfires only when the sweep found nothing,
	# which is the healthy state and the one nobody would think to check.
	awk -F'\t' -v dirtyfile="$DIRTY" '
		FILENAME == dirtyfile { dirty[$0] = 1; next }
		{
			seen[$2] = 1
			print ($2 in dirty ? "dirty" : $1) "\t" $2
		}
		END { for (b in dirty) if (!(b in seen)) print "dirty\t" b }
	' "$DIRTY" "$CACHE" 2>/dev/null
}

case "${1:-}" in
--refresh)
	__mb_refresh || {
		echo "merged-branches: could not read ${BASE_REF} in ${REPO_DIR}" >&2
		exit 1
	}
	__mb_refresh_dirty
	__mb_join | awk -F'\t' '{ n[$1]++ } END { printf "%d merged, %d empty, %d dirty\n", n["merged"], n["empty"], n["dirty"] }'
	;;
--refresh-dirty)
	__mb_refresh_dirty || {
		echo "merged-branches: could not sweep ${WORKTREE_DIR}" >&2
		exit 1
	}
	printf '%s dirty\n' "$(wc -l <"$DIRTY" | tr -d ' ')"
	;;
--stamp)
	if [ -f "$STAMP" ]; then
		printf 'base %s, branches %dm ago, dirty %s\n' \
			"$(sed -n 2p "$STAMP")" \
			"$((($(date +%s) - $(head -1 "$STAMP")) / 60))" \
			"$(if [ -f "$DIRTY_STAMP" ]; then
				printf '%ds ago' "$(($(date +%s) - $(head -1 "$DIRTY_STAMP")))"
			else printf 'never'; fi)"
		__mb_join | awk -F'\t' '{ n[$1]++ } END { printf "%d merged, %d empty, %d dirty\n", n["merged"], n["empty"], n["dirty"] }'
	else
		echo "no cache yet"
	fi
	;;
*)
	# Serve first, refresh after. The popup opening is what the user is waiting
	# on; a recompute in front of it would be felt every single time.
	__mb_join

	# Detached with their streams closed, exactly as notify.sh must be: a child
	# still holding the inherited pipe keeps the caller's command substitution
	# open, and the popup hangs waiting for EOF.
	#
	# Separately, because they expire an order of magnitude apart -- the dirty
	# sweep going stale every minute must not drag the ~5s branch pass along
	# with it.
	__mb_stale && ("$0" --refresh) >/dev/null 2>&1 &
	__mb_dirty_stale && ("$0" --refresh-dirty) >/dev/null 2>&1 &
	;;
esac
