#!/usr/bin/env bash
# Tests for merged-branches.sh, against a throwaway repo with real merges.
#
# The interesting case is the squash merge, because that is the one
# `git branch --merged` cannot see and the one this repo's main is built from.
# Fixtures create genuine squash commits rather than simulating them: the whole
# claim under test is about patch-ids, and a fake would not have the right one.
#
# The rest of the file is mostly about the ways this reported unstarted work as
# finished. Every one of those is pinned here, because each was wrong in the
# same direction -- towards offering up a worktree that still had something in
# it -- and that is the only direction that costs anything.
#
#   ./merged-branches.test.sh

set -u

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
SCRIPT="$(cd .. && pwd)/merged-branches.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
pass() {
	PASS=$((PASS + 1))
	printf '  ok   %s\n' "$1"
}
fail() {
	FAIL=$((FAIL + 1))
	printf '  FAIL %s\n' "$1"
	shift
	local l
	for l in "$@"; do printf '         %s\n' "$l"; done
}

# The output is `<state>\t<branch>`, and a branch with no line is outstanding
# work. Asserting on the pair rather than on the branch alone is the point:
# every bug this file exists for was a branch appearing under the wrong state,
# not a branch going missing.
state_of() {
	awk -F'\t' -v b="$1" '$2 == b { print $1; found = 1 }
		END { if (!found) print "-" }' <<<"$OUT"
}
assert_state() {
	local got
	got=$(state_of "$1")
	if [ "$got" = "$2" ]; then pass "$3"; else
		fail "$3" "expected $1 to be '$2', got '$got'"
	fi
}

REPO="${WORK}/repo"
TREES="${WORK}/worktrees"
mkdir -p "$REPO" "$TREES"

git -C "$REPO" init -q -b main
git -C "$REPO" config user.email t@t
git -C "$REPO" config user.name t
printf 'base\n' >"${REPO}/base.txt"
git -C "$REPO" add -A
git -C "$REPO" commit -qm base

# Stands in for upstream/main. The real one is a remote-tracking ref, but every
# operation here treats it as an ordinary committish.
git -C "$REPO" branch trunk

commit_on() { # branch file content
	git -C "$REPO" checkout -q -b "$1" main 2>/dev/null || git -C "$REPO" checkout -q "$1"
	printf '%s\n' "$3" >"${REPO}/$2"
	git -C "$REPO" add -A
	git -C "$REPO" commit -qm "$2"
}

# Squash-merged into trunk: several commits collapsed into one, which is what
# GitHub does and the reason ancestry cannot answer the question.
commit_on squashed a.txt one
printf 'two\n' >"${REPO}/b.txt"
git -C "$REPO" add -A && git -C "$REPO" commit -qm two
git -C "$REPO" checkout -q trunk
git -C "$REPO" merge --squash -q squashed >/dev/null
git -C "$REPO" commit -qm "squashed PR (#1)"

# Merged the ordinary way, so it IS an ancestor of trunk.
commit_on truly c.txt merged
git -C "$REPO" checkout -q trunk
git -C "$REPO" merge -q --no-ff truly -m "merge truly"

# Live work, on neither trunk nor anywhere else.
commit_on live d.txt wip

# Trunk moves on afterwards. A branch does not become unmerged because main
# advanced, and the patch-id test has to survive that.
git -C "$REPO" checkout -q trunk
printf 'later\n' >"${REPO}/e.txt"
git -C "$REPO" add -A && git -C "$REPO" commit -qm later

# Branched and never committed to -- the shape that broke this. Its tree equals
# its merge base, so its collapsed patch is empty.
git -C "$REPO" branch fresh main

git -C "$REPO" checkout -q main

for b in squashed truly live fresh main trunk; do
	git -C "$REPO" worktree add -q "${TREES}/${b}" "$b" 2>/dev/null ||
		mkdir -p "${TREES}/${b}"
done

export CC_MERGED_REPO="$REPO"
export CC_MERGED_WORKTREES="$TREES"
export CC_MERGED_BASE=trunk
export CC_MERGED_CACHE_DIR="${WORK}/cache"

"$SCRIPT" --refresh >/dev/null
OUT=$("$SCRIPT")

printf 'detection\n'
assert_state squashed merged "a squash-merged branch is detected"
assert_state live - "an unmerged branch is not detected"

# Not `merged`, and this is a real limit rather than an oversight. An ancestor
# of trunk has an empty patch for the same structural reason a fresh branch
# does, and nothing local separates the two -- so both land in `empty`, which
# means "no commits that are not already on main". Equally safe to remove, and
# the reason the note attached to that state cannot say "no commits yet".
assert_state truly empty "a conventionally merged branch reads as empty, not merged"

# The claim that motivates the whole file: ancestry alone misses the squash.
if git -C "$REPO" branch --merged trunk --format='%(refname:short)' | grep -qx squashed; then
	fail "git branch --merged does NOT see the squash merge" "it listed squashed"
else pass "git branch --merged does NOT see the squash merge"; fi

printf 'empty branches\n'

# The bug this file was written after. An empty patch is trivially already
# upstream, so `git cherry` calls an untouched worktree merged -- 30 of 103 on
# the machine this runs on, which is what a delete list would have offered up.
assert_state fresh empty "a branch with no commits is empty, not merged"

# And the reason the second opinion had to go rather than be corrected: an
# ancestor's merge base IS its tip, so the ancestor test can only ever fire on
# branches whose collapsed patch is empty. It cannot contribute a detection.
n=0
while read -r b; do
	[ -n "$b" ] || continue
	mb=$(git -C "$REPO" merge-base trunk "$b" 2>/dev/null) || continue
	[ "$(git -C "$REPO" rev-parse "${b}^{tree}")" != "$(git -C "$REPO" rev-parse "${mb}^{tree}")" ] && n=$((n + 1))
done < <(git -C "$REPO" branch --merged trunk --format='%(refname:short)')
if [ "$n" -eq 0 ]; then
	pass "git branch --merged can only ever fire on empty-patch branches"
else
	fail "git branch --merged can only ever fire on empty-patch branches" "$n had a real diff"
fi

# The base branch itself is empty by this measure, accurately -- it has no
# commits main does not -- and would sort to the top of a list offering to
# delete it. `trunk` here is what upstream/main is in the real repo.
assert_state trunk - "the base branch is excluded entirely"

# Only the base. A worktree that merely sits on some other long-lived branch is
# still an ordinary candidate, so the exclusion cannot be a general "skip
# branches that look important".
assert_state main empty "a non-base branch with no commits is still classified"

printf 'uncommitted changes\n'

# Uncommitted work has landed nowhere whatever the commits say, so it outranks
# both other states. Tested on a merged branch and an empty one, because those
# are exactly the two that would otherwise be offered up.
printf 'edited\n' >>"${TREES}/squashed/a.txt"
printf 'brand new\n' >"${TREES}/fresh/untracked.txt"
"$SCRIPT" --refresh >/dev/null
OUT=$("$SCRIPT")

assert_state squashed dirty "a merged branch with local edits is dirty, not merged"
assert_state fresh dirty "an empty branch with an untracked file is dirty, not empty"
assert_state live - "a clean branch is unaffected by another's dirt"

# Untracked files specifically, because `git worktree remove` refuses over them
# too -- ignoring them would put rows in the list that cannot be removed.
rm -f "${TREES}/squashed/a.txt.orig"
git -C "${TREES}/squashed" checkout -- a.txt
"$SCRIPT" --refresh-dirty >/dev/null
OUT=$("$SCRIPT")
assert_state squashed merged "reverting the edit restores the merged state"
assert_state fresh dirty "an untracked file alone still counts as dirty"

printf 'cache\n'

# The two caches expire an order of magnitude apart, so the dirty sweep going
# stale every minute must not drag the ~5s branch pass along with it.
branch_before=$(cat "${CC_MERGED_CACHE_DIR}/merged-branches")
rm -f "${TREES}/fresh/untracked.txt"
"$SCRIPT" --refresh-dirty >/dev/null
if [ "$(cat "${CC_MERGED_CACHE_DIR}/merged-branches")" = "$branch_before" ]; then
	pass "a dirty-only refresh leaves the branch cache untouched"
else
	fail "a dirty-only refresh leaves the branch cache untouched" "it was rewritten"
fi
OUT=$("$SCRIPT")
assert_state fresh empty "removing the untracked file returns it to empty"

# Nothing is dirty now, so the dirty cache is an empty file -- which is the
# input that broke the join. `NR == FNR` stays true into the second file when
# the first yields no records, so every branch got filed as dirty and came back
# out marked dirty. It misfires only when the sweep found nothing, which is the
# healthy state, so it has to be asserted rather than assumed.
if [ -s "${CC_MERGED_CACHE_DIR}/merged-branches.dirty" ]; then
	fail "the empty dirty cache is the case under test" "the file was not empty"
elif grep -q '^dirty' <<<"$OUT"; then
	fail "an empty dirty cache marks nothing dirty" "got: $(grep '^dirty' <<<"$OUT" | tr '\n' ' ')"
else
	pass "an empty dirty cache marks nothing dirty"
fi

# Same input, second failure mode: the corrupted rows carried three fields.
if awk -F'\t' 'NF != 2 { bad = 1 } END { exit !bad }' <<<"$OUT"; then
	fail "every joined row has exactly two fields" "got: $(head -1 <<<"$OUT")"
else
	pass "every joined row has exactly two fields"
fi

# The base moving is what changes the answer, so the stamp records it and a
# changed base counts as stale however recent the cache is.
if sed -n 2p "${CC_MERGED_CACHE_DIR}/merged-branches.stamp" |
	grep -qx "$(git -C "$REPO" rev-parse --short trunk)"; then
	pass "the stamp records the base the cache was built against"
else
	fail "the stamp records the base the cache was built against"
fi

# Serving branch states alone beats serving nothing when no sweep has run yet.
rm -f "${CC_MERGED_CACHE_DIR}/merged-branches.dirty"
OUT=$("$SCRIPT" 2>/dev/null)
assert_state squashed merged "the branch cache is served alone when no dirty sweep exists"
"$SCRIPT" --refresh-dirty >/dev/null

printf 'robustness\n'

# A worktree directory with no branch behind it is a leftover, not an error.
mkdir -p "${TREES}/orphan-dir"
OUT=$("$SCRIPT" --refresh 2>&1 && "$SCRIPT")
assert_state orphan-dir - "a worktree dir with no branch is skipped"

# Ending on an unmerged branch must not make the whole run look like a failure
# -- the function returns the status of its last test otherwise.
if "$SCRIPT" --refresh >/dev/null 2>&1; then
	pass "a run ending on an unmerged branch still succeeds"
else
	fail "a run ending on an unmerged branch still succeeds" "exit was non-zero"
fi

# Enough clean worktrees that xargs would see a run of non-zero child exits.
# Under `&&` rather than `if`, that makes xargs return 123 and the whole sweep
# gets discarded as failed.
for i in 1 2 3 4 5 6 7 8; do
	git -C "$REPO" branch "clean$i" main 2>/dev/null
	git -C "$REPO" worktree add -q "${TREES}/clean$i" "clean$i" 2>/dev/null
done
if "$SCRIPT" --refresh-dirty >/dev/null 2>&1; then
	pass "a sweep where most worktrees are clean still succeeds"
else
	fail "a sweep where most worktrees are clean still succeeds" "exit was non-zero"
fi

# A base ref that does not exist is a misconfiguration and has to say so rather
# than silently reporting that nothing is merged.
if CC_MERGED_BASE=nope "$SCRIPT" --refresh >/dev/null 2>&1; then
	fail "an unknown base ref fails loudly" "exit was zero"
else
	pass "an unknown base ref fails loudly"
fi

# ...and must not have destroyed the good cache on its way out.
OUT=$("$SCRIPT")
assert_state squashed merged "a failed refresh leaves the previous cache intact"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
