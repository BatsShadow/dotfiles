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
# Output is one `<state>\t<branch>\t<mtime>` line per worktree branch that is
# not simply outstanding work, where state is `dirty`, `merged` or `empty`.
#
# mtime is when the uncommitted work in that tree was last written, and is set
# only on `dirty` rows -- it is a by-product of the sweep that found them, which
# had to name the changed files anyway. Nothing here reports when a branch was
# last committed to: `git for-each-ref` answers that for every branch at once in
# a single call, so a caller that wants it is better off asking directly than
# waiting on a cache built for a question that costs seconds.
#
# Two caches, because the two questions decay at completely different rates.
# Whether a branch landed changes when someone merges a PR and a worktree you
# finished with never becomes unfinished, so 15 minutes stale costs one extra
# row. Whether a tree is dirty changes the moment you save a file, so it gets a
# minute. They are computed and stored separately and joined on read.
#
# Both are cached rather than computed on demand because these run inside popups
# that must open instantly: over 103 worktrees the branch pass is ~0.9s and the
# dirty pass ~2.3s, both already fanned out twelve ways. Readers get whatever the
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

# One `git status` per worktree for the dirty pass, five short-lived git
# processes per branch for the patch test. Both are independent per worktree and
# both spend most of their time waiting on the disk, so both fan out. Serially
# the branch pass took 5s over 103 worktrees; twelve ways it takes 0.9s for a
# byte-identical answer, which is most of the reason it is bearable to recompute
# at all. The older CC_MERGED_DIRTY_JOBS still works.
JOBS="${CC_MERGED_JOBS:-${CC_MERGED_DIRTY_JOBS:-12}}"

# `merged` or `empty` per worktree branch, and nothing at all for a branch with
# outstanding work.
#
# The classification runs in the xargs child rather than in a shell function,
# because a function cannot cross into `sh -c`. Exporting the settings it reads
# is the price of the parallelism.
__mb_compute() {
	git -C "$REPO_DIR" rev-parse --verify --quiet "$BASE_REF" >/dev/null 2>&1 || return 1

	export REPO_DIR BASE_REF
	# The trunk is not work in progress and is never finished with. Left
	# unclassified it reads as `empty`, perfectly accurately -- it has no commits
	# of its own -- and lands at the top of a list offering to delete it.
	MB_TRUNK="${BASE_REF##*/}"
	export MB_TRUNK

	# Sorted on the way out. The order xargs finishes in is whatever the disk
	# decides, and a cache that reshuffles itself every refresh is impossible to
	# diff against the last one when something looks wrong.
	find "$WORKTREE_DIR" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null |
		xargs -0 -P "$JOBS" -n1 sh -c '
			b=${1##*/}
			[ "$b" = "$MB_TRUNK" ] && exit 0
			git -C "$REPO_DIR" show-ref --verify --quiet "refs/heads/$b" || exit 0

			mb=$(git -C "$REPO_DIR" merge-base "$BASE_REF" "$b" 2>/dev/null) || exit 0
			[ -n "$mb" ] || exit 0
			tree=$(git -C "$REPO_DIR" rev-parse "$b^{tree}" 2>/dev/null) || exit 0
			base=$(git -C "$REPO_DIR" rev-parse "$mb^{tree}" 2>/dev/null) || exit 0

			# Nothing of its own. Must be answered before the patch test rather
			# than by it: an empty patch is trivially already upstream, so
			# `git cherry` would call every untouched worktree merged.
			if [ "$tree" = "$base" ]; then
				printf "empty\t%s\n" "$b"
				exit 0
			fi

			syn=$(git -C "$REPO_DIR" commit-tree "$tree" -p "$mb" -m merged-probe 2>/dev/null) || exit 0

			# `-` prefixes a commit whose patch is already upstream. Anything
			# else, including no output at all, means it is not. Exit 0 either
			# way: enough non-zero children in a row and xargs gives up with
			# 123, which __mb_refresh would read as a failed sweep and discard.
			if git -C "$REPO_DIR" cherry "$BASE_REF" "$syn" 2>/dev/null | grep -q "^-"; then
				printf "merged\t%s\n" "$b"
			fi
			exit 0
		' _ | sort -t"$(printf '\t')" -k2,2

	return 0
}

# Every worktree with anything uncommitted in it, as `<branch>\t<mtime>`, where
# mtime is when the most recently written of those changes was last touched.
# Untracked files count: `git worktree remove` refuses over them too, so leaving
# them out would put rows in the list that cannot actually be removed.
#
# The time comes from here rather than from the caller because this is the only
# pass that knows which files are dirty. Having paid for `git status` already,
# stat-ing the paths it named is the whole cost -- the alternative, walking the
# worktree for its newest file, would have to be told what git already knows
# about ignores.
__mb_compute_dirty() {
	[ -d "$WORKTREE_DIR" ] || return 1

	# GNU and BSD stat spell "modified time" with different flags and reject each
	# other's. Settled once, here, rather than per worktree -- and it cannot be
	# settled by falling back inside the pipeline, because the first stat would
	# have drained the path list before the second ever ran.
	if stat -f %m . >/dev/null 2>&1; then
		MB_STAT="-f%m"
	else
		MB_STAT="-c%Y"
	fi
	export MB_STAT

	# `if` rather than `&&` so the child always exits 0. Under `&&` a clean
	# worktree is a non-zero exit, and enough of those make xargs give up and
	# return 123 -- which __mb_refresh_dirty would read as "the sweep failed"
	# and discard a complete, correct result.
	find "$WORKTREE_DIR" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null |
		xargs -0 -P "$JOBS" -n1 sh -c '
			st=$(git -C "$1" status --porcelain 2>/dev/null)
			if [ -n "$st" ]; then
				# Strip the two status columns, keep the destination of a
				# rename, and unwrap the quoting git puts round an awkward
				# name. A path that survives none of that stats as nothing
				# and drops out of the max, costing at worst a slightly old
				# time on a row that is dirty either way.
				when=$(printf "%s\n" "$st" |
					sed -e "s/^...//" -e "s/.* -> //" \
						-e "s/^\"//" -e "s/\"$//" |
					tr "\n" "\0" |
					(cd "$1" && xargs -0 stat $MB_STAT 2>/dev/null) |
					sort -rn | head -1)
				printf "%s\t%s\n" "$(basename "$1")" "$when"
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
	# Padded to the full width so readers never have to handle two shapes.
	if [ ! -f "$DIRTY" ]; then
		awk '{ print $0 "\t" }' "$CACHE"
		return 0
	fi

	# Keyed on FILENAME rather than the usual `NR == FNR`, which is wrong here
	# in the one case that matters most. When nothing is dirty the first file is
	# empty, so awk reads no record from it and NR == FNR is still true on the
	# first line of the second -- every branch would be filed as dirty and come
	# back out marked dirty. It misfires only when the sweep found nothing,
	# which is the healthy state and the one nobody would think to check.
	awk -F'\t' -v dirtyfile="$DIRTY" '
		FILENAME == dirtyfile { dirty[$1] = 1; when[$1] = $2; next }
		{
			seen[$2] = 1
			if ($2 in dirty) print "dirty\t" $2 "\t" when[$2]
			else print $1 "\t" $2 "\t"
		}
		END { for (b in dirty) if (!(b in seen)) print "dirty\t" b "\t" when[b] }
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

	# Detached with every stream closed, exactly as notify.sh must be: a child
	# still holding the inherited pipe keeps the caller's read open, and the
	# popup blocks for as long as the refresh takes.
	#
	# The staleness test has to sit outside the backgrounded job, not in front of
	# it as `__mb_stale && (...) &`. That form backgrounds the whole AND-list,
	# and the shell running the list holds the inherited stdout for the duration
	# -- the redirection binds to the subshell only. It reads as equivalent and
	# costs 2.3s a popup.
	#
	# Two tests rather than one, because the caches expire an order of magnitude
	# apart: the dirty sweep going stale every minute must not drag the ~5s
	# branch pass along behind it.
	if __mb_stale; then
		("$0" --refresh) >/dev/null 2>&1 </dev/null &
	fi
	if __mb_dirty_stale; then
		("$0" --refresh-dirty) >/dev/null 2>&1 </dev/null &
	fi
	;;
esac
