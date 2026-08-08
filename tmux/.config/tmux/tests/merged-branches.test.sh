#!/usr/bin/env bash
# Tests for merged-branches.sh, against a throwaway repo with real merges.
#
# The interesting case is the squash merge, because that is the one
# `git branch --merged` cannot see and the one this repo's main is built from.
# Fixtures create genuine squash commits rather than simulating them: the whole
# claim under test is about patch-ids, and a fake would not have the right one.
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
assert_has() {
	if printf '%s\n' "$1" | grep -qx "$2"; then pass "$3"; else
		fail "$3" "expected to list: $2" "got: $(printf '%s' "$1" | tr '\n' ' ')"
	fi
}
assert_lacks() {
	if printf '%s\n' "$1" | grep -qx "$2"; then
		fail "$3" "expected NOT to list: $2" "got: $(printf '%s' "$1" | tr '\n' ' ')"
	else pass "$3"; fi
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

# A branch squash-merged into trunk: several commits collapsed into one. This is
# what GitHub does, and the reason ancestry cannot answer the question -- none
# of squashed's commits exist on trunk.
git -C "$REPO" checkout -q -b squashed main
printf 'one\n' >"${REPO}/a.txt"
git -C "$REPO" add -A && git -C "$REPO" commit -qm one
printf 'two\n' >"${REPO}/b.txt"
git -C "$REPO" add -A && git -C "$REPO" commit -qm two
git -C "$REPO" checkout -q trunk
git -C "$REPO" merge --squash -q squashed >/dev/null
git -C "$REPO" commit -qm "squashed PR (#1)"

# A branch merged the ordinary way, so it IS an ancestor of trunk.
git -C "$REPO" checkout -q -b truly main
printf 'merged\n' >"${REPO}/c.txt"
git -C "$REPO" add -A && git -C "$REPO" commit -qm c
git -C "$REPO" checkout -q trunk
git -C "$REPO" merge -q --no-ff truly -m "merge truly"

# Live work: on neither trunk nor anywhere else.
git -C "$REPO" checkout -q -b live main
printf 'wip\n' >"${REPO}/d.txt"
git -C "$REPO" add -A && git -C "$REPO" commit -qm wip

# Trunk moves on afterwards. A branch does not become unmerged because main
# advanced, and the patch-id test has to survive that.
git -C "$REPO" checkout -q trunk
printf 'later\n' >"${REPO}/e.txt"
git -C "$REPO" add -A && git -C "$REPO" commit -qm later

git -C "$REPO" checkout -q main

for b in squashed truly live; do mkdir -p "${TREES}/${b}"; done

export CC_MERGED_REPO="$REPO"
export CC_MERGED_WORKTREES="$TREES"
export CC_MERGED_BASE=trunk
export CC_MERGED_CACHE_DIR="${WORK}/cache"

printf 'detection\n'
"$SCRIPT" --refresh >/dev/null
out=$("$SCRIPT")

assert_has "$out" "squashed" "a squash-merged branch is detected"
assert_has "$out" "truly" "a conventionally merged branch is detected"
assert_lacks "$out" "live" "an unmerged branch is not detected"

# The claim that motivates the whole file: ancestry alone misses the squash.
anc=$(git -C "$REPO" branch --merged trunk --format='%(refname:short)')
assert_lacks "$anc" "squashed" "git branch --merged does NOT see the squash merge"
assert_has "$anc" "truly" "git branch --merged does see the ordinary merge"

printf 'cache\n'

# A worktree whose branch was never merged must not appear just because the
# cache was warm. It needs a commit of its own: a branch left pointing at main
# is an ancestor of trunk and so is merged, correctly but uninterestingly.
mkdir -p "${TREES}/newcomer"
git -C "$REPO" checkout -q -b newcomer main
printf 'new\n' >"${REPO}/f.txt"
git -C "$REPO" add -A && git -C "$REPO" commit -qm new
git -C "$REPO" checkout -q main
"$SCRIPT" --refresh >/dev/null
assert_lacks "$(cat "${CC_MERGED_CACHE_DIR}/merged-branches")" "newcomer" \
	"a fresh unmerged branch stays out after a refresh"

# The base moving is what changes the answer, so the stamp records it and a
# changed base counts as stale however recent the cache is.
stamp_base=$(sed -n 2p "${CC_MERGED_CACHE_DIR}/merged-branches.stamp")
assert_has "$stamp_base" "$(git -C "$REPO" rev-parse --short trunk)" \
	"the stamp records the base the cache was built against"

printf 'robustness\n'

# A worktree directory with no branch behind it is a leftover, not an error.
mkdir -p "${TREES}/orphan-dir"
out=$("$SCRIPT" --refresh 2>&1)
assert_lacks "$out" "orphan-dir" "a worktree dir with no branch is skipped"

# Ending on an unmerged branch must not make the whole run look like a failure
# -- the function returns the status of its last test otherwise.
if "$SCRIPT" --refresh >/dev/null 2>&1; then
	pass "a run ending on an unmerged branch still succeeds"
else
	fail "a run ending on an unmerged branch still succeeds" "exit was non-zero"
fi

# A base ref that does not exist is a misconfiguration and has to say so rather
# than silently reporting that nothing is merged.
if CC_MERGED_BASE=nope "$SCRIPT" --refresh >/dev/null 2>&1; then
	fail "an unknown base ref fails loudly" "exit was zero"
else
	pass "an unknown base ref fails loudly"
fi

# ...and must not have destroyed the good cache on its way out.
assert_has "$(cat "${CC_MERGED_CACHE_DIR}/merged-branches")" "squashed" \
	"a failed refresh leaves the previous cache intact"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
