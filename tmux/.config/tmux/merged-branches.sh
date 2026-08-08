#!/usr/bin/env bash
# Which worktree branches have already landed on upstream/main.
#
# main is squash-merged, so `git branch --merged` is close to useless on its
# own: a squashed branch shares no commit with main and is never an ancestor of
# it. Measured against this repo it found 31 of the 73 reclaimable worktrees.
#
# Two tests, which turn out to be complementary by construction:
#
#   ancestor    `git branch --merged upstream/main`. Catches real merges.
#
#   squash      Collapse the branch to a single commit carrying its tree, on
#               top of its merge base, then ask `git cherry` whether that patch
#               is already upstream. A squash commit's diff is exactly the
#               branch's diff against the merge base, so the patch-ids match.
#
# Neither sees what the other sees. A truly merged branch has a collapsed diff
# of nothing, so the squash test cannot fire on it; a squashed branch is not an
# ancestor, so the first test cannot fire either. Together they found 71 of 73.
# Checked against `gh pr list --state merged`, the squash test agreed on all 40
# of the squash-merged branches -- so the offline answer is the same answer,
# without a network round trip. The 2 it misses are PRs whose conflicts were
# resolved during the merge, which changes the patch and is not recoverable
# locally at any price.
#
# Cached because a full pass is ~5s over 103 worktrees -- four git processes per
# branch -- and these run inside popups that must open instantly. Readers get
# whatever the cache holds and never block; a stale or missing cache means marks
# are absent, never wrong, and the row still renders.
#
#   merged-branches.sh              print the cached set, refreshing behind you
#   merged-branches.sh --refresh    recompute now, synchronously
#   merged-branches.sh --stamp      print the cache's age and base ref

set -u

REPO_DIR="${CC_MERGED_REPO:-$HOME/src/upngo/upngo-web}"
WORKTREE_DIR="${CC_MERGED_WORKTREES:-$HOME/src/upngo/worktrees}"
BASE_REF="${CC_MERGED_BASE:-upstream/main}"
CACHE_DIR="${CC_MERGED_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/tmux-claude}"
CACHE="${CACHE_DIR}/merged-branches"
STAMP="${CACHE_DIR}/merged-branches.stamp"

# How long a cached answer stays good. Branches land continuously but a worktree
# you finished with does not become un-finished, so the cost of being a few
# minutes behind is one extra row in a cleanup list.
TTL="${CC_MERGED_TTL:-900}"

# One commit that carries the branch's tree on top of its merge base. Its diff
# against the base is the whole branch as one patch -- the same patch a squash
# merge produced -- so `git cherry` can match it by patch-id.
__mb_squashed_into_base() {
	local branch="$1" mb tree synthetic

	mb=$(git -C "$REPO_DIR" merge-base "$BASE_REF" "$branch" 2>/dev/null) || return 1
	[ -n "$mb" ] || return 1

	tree=$(git -C "$REPO_DIR" rev-parse "${branch}^{tree}" 2>/dev/null) || return 1
	synthetic=$(git -C "$REPO_DIR" commit-tree "$tree" -p "$mb" -m merged-probe 2>/dev/null) || return 1

	# `-` prefixes a commit whose patch is already upstream. Anything else,
	# including no output at all, means it is not.
	git -C "$REPO_DIR" cherry "$BASE_REF" "$synthetic" 2>/dev/null | grep -q '^-'
}

__mb_compute() {
	local ancestors branch

	git -C "$REPO_DIR" rev-parse --verify --quiet "$BASE_REF" >/dev/null 2>&1 || return 1

	ancestors=$(git -C "$REPO_DIR" branch --merged "$BASE_REF" --format='%(refname:short)' 2>/dev/null)

	for dir in "$WORKTREE_DIR"/*/; do
		[ -d "$dir" ] || continue
		branch="${dir%/}"
		branch="${branch##*/}"

		if printf '%s\n' "$ancestors" | grep -qxF "$branch"; then
			printf '%s\n' "$branch"
			continue
		fi

		git -C "$REPO_DIR" show-ref --verify --quiet "refs/heads/${branch}" || continue
		__mb_squashed_into_base "$branch" && printf '%s\n' "$branch"
	done

	# Explicit, because otherwise the function returns the status of the last
	# branch tested -- so a run ending on an unmerged branch would report
	# failure, and the caller would throw away a perfectly good result.
	return 0
}

__mb_refresh() {
	mkdir -p "$CACHE_DIR" 2>/dev/null || return 1

	# Written whole and renamed into place. A reader that catches a half-written
	# cache would silently drop marks from rows that have them, which is a
	# worse failure than being a few minutes stale.
	local tmp="${CACHE}.tmp.$$"
	if __mb_compute >"$tmp" 2>/dev/null; then
		mv -f "$tmp" "$CACHE"
		printf '%s\n%s\n' \
			"$(date +%s)" \
			"$(git -C "$REPO_DIR" rev-parse --short "$BASE_REF" 2>/dev/null)" >"$STAMP"
	else
		rm -f "$tmp"
		return 1
	fi
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

case "${1:-}" in
--refresh)
	__mb_refresh || {
		echo "merged-branches: could not read ${BASE_REF} in ${REPO_DIR}" >&2
		exit 1
	}
	wc -l <"$CACHE" | tr -d ' '
	;;
--stamp)
	if [ -f "$STAMP" ]; then
		printf 'base %s, computed %dm ago, %s branches merged\n' \
			"$(sed -n 2p "$STAMP")" \
			"$((($(date +%s) - $(head -1 "$STAMP")) / 60))" \
			"$(wc -l <"$CACHE" | tr -d ' ')"
	else
		echo "no cache yet"
	fi
	;;
*)
	# Serve first, refresh after. The popup opening is what the user is waiting
	# on; a five second recompute in front of it would be felt every time.
	[ -f "$CACHE" ] && cat "$CACHE"
	if __mb_stale; then
		# Detached with its streams closed, exactly as notify.sh must be: a
		# child still holding the inherited pipe keeps the caller's command
		# substitution open, and the popup hangs waiting for EOF.
		("$0" --refresh) >/dev/null 2>&1 &
	fi
	;;
esac
