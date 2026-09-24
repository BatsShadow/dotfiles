#!/usr/bin/env bash
# Work that exists nowhere else survives an apply. An edit made while the apply
# fetches is not overwritten, and the worktree as it stood is kept in a local
# ref before any checkout. A worktree that cannot be read is not taken for an
# absent one, a local branch with commits the other side lacks is not reset,
# a followed removal keeps the excluded files first, an edit to a tracked file
# an exclude matches is seen like any other, and an amend on the other side
# still applies.
#
#   ./safety.test.sh

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

machine a
machine b

# a repo both machines have in sync, where a has just changed
synced() { # name
	github_repo "$1" a "src/$1"
	on a publish
	on b apply
	on b publish
	on a apply
}

printf 'an edit made while the apply fetches\n'

# A fetch takes seconds and nothing can pause a real one at the right moment,
# so the test wraps fetch_theirs to make the edit and then run the real fetch.
# Everything else is the real cmd_apply over real repos.
synced app
echo "a's change" >>"$(home a)/src/app/README"
on a publish
lib b eval '
	eval "real_fetch_theirs() $(declare -f fetch_theirs | tail -n +2)"
	fetch_theirs() { echo "typed mid-apply" >>"$HOME_P/src/app/README"; real_fetch_theirs "$@"; }
	cmd_apply' 2>>"$WORK/b.log"
assert_eq "hello
typed mid-apply" "$(cat "$(home b)/src/app/README")" "the edit survives"
assert_eq 1 "$(grep -c 'src/app: changed while applying; next run' "$WORK/b.log")" "and b says why"

printf 'the worktree as it stood, kept before the apply\n'

synced snap
echo "b's wip" >>"$(home b)/src/snap/README"
echo "b's note" >"$(home b)/src/snap/note"
on b publish
on a apply
echo "a's change" >"$(home a)/src/snap/other"
on a publish
before=$(lib b worktree_tree "$(home b)/src/snap")
on b apply
assert_eq "$before" "$(g b src/snap rev-parse -q --verify 'refs/srcsync-local/src/snap/before-apply^{tree}')" \
	"b's worktree tree is in the before-apply ref"
assert_eq "srcsync before apply" \
	"$(g b src/snap reflog show --format=%gs refs/srcsync-local/src/snap/before-apply 2>/dev/null | head -1)" \
	"with a reflog entry"
on b publish
assert_eq "" "$(git -C "$GH/hub.git" for-each-ref refs/srcsync-local; git -C "$GH/snap.git" for-each-ref refs/srcsync-local)" \
	"and it is never pushed"

printf 'a repo with no commits\n'

github_repo raw a src/raw
on a publish
git init -q "$(home b)/src/raw"
git -C "$(home b)/src/raw" remote add origin "$GH/raw.git"
echo "b's only copy" >"$(home b)/src/raw/precious"
echo "b's readme" >"$(home b)/src/raw/README"
on b apply
assert_eq "b's only copy" "$(cat "$(home b)/src/raw/precious" 2>/dev/null)" "an untracked file survives"
assert_eq "b's readme" "$(cat "$(home b)/src/raw/README" 2>/dev/null)" "a file a also has survives"
assert_eq 1 "$(grep -c 'src/raw: cannot read it here; skipped' "$WORK/b.log")" "and b says why"

printf 'a worktree git cannot read\n'

synced lock
echo "b's work" >>"$(home b)/src/lock/README"
echo "unreadable" >"$(home b)/src/lock/locked"
chmod 000 "$(home b)/src/lock/locked"
echo "a's change" >"$(home a)/src/lock/other"
on a publish
on b apply
chmod 644 "$(home b)/src/lock/locked" 2>/dev/null
assert_eq "hello
b's work" "$(cat "$(home b)/src/lock/README")" "b's edit survives"
assert_eq "unreadable" "$(cat "$(home b)/src/lock/locked" 2>/dev/null)" "so does the unreadable file"
assert_eq 1 "$(grep -c 'src/lock: cannot read it here; skipped' "$WORK/b.log")" "and b says why"

printf 'a local branch the other side lacks commits of\n'

synced feat
g b src/feat checkout -q -b feature
echo "b's feature" >"$(home b)/src/feat/b-feature"
g b src/feat add b-feature
g b src/feat commit -q -m "b's feature"
mine=$(g b src/feat rev-parse feature)
g b src/feat checkout -q main
g a src/feat checkout -q -b feature
echo "a's feature" >"$(home a)/src/feat/a-feature"
g a src/feat add a-feature
g a src/feat commit -q -m "a's feature"
on a publish
on b apply
assert_eq "$mine" "$(g b src/feat rev-parse feature)" "b's feature keeps b's commit"
assert_eq "main" "$(g b src/feat branch --show-current)" "b's worktree stays where it was"
assert_eq "src/feat a" \
	"$(jq -r '.[] | "\(.worktree) \(.host)"' "$(home b)/.local/state/srcsync/conflicts.json" | grep feat)" \
	"b records the conflict with a"
assert_eq 1 "$(grep -c 'src/feat: branch feature has commits here that a lacks; left alone' "$WORK/b.log")" \
	"and says why"

printf 'a branch the other side amended\n'

synced amend
g a src/amend checkout -q -b feat
echo "one" >"$(home a)/src/amend/f"
g a src/amend add f
g a src/amend commit -q -m "feat"
on a publish
on b apply
on b publish
on a apply
old=$(g b src/amend rev-parse feat)
echo "two" >"$(home a)/src/amend/f"
g a src/amend commit -q -a --amend -m "feat, amended"
on a publish
on b apply
assert_eq "$(g a src/amend rev-parse HEAD)" "$(g b src/amend rev-parse HEAD)" "b takes a's amended commit"
assert_eq "" "$(jq -r '.[] | select(.worktree == "src/amend") | .worktree' \
	"$(home b)/.local/state/srcsync/conflicts.json")" "with no conflict"
g b src/amend merge-base --is-ancestor "$old" refs/srcsync-local/src/amend/before-apply 2>/dev/null
assert_eq 0 "$?" "and b's old commit is kept in the before-apply ref"

printf 'a followed removal over excluded files\n'

printf 'an excluded directory the apply must not clean\n'

printf 'exclude .env\nexclude secrets\n' >"$(home b)/.config/srcsync/config"
synced sec
mkdir "$(home b)/src/sec/secrets"
echo "b's key" >"$(home b)/src/sec/secrets/key.txt"
on b publish
on a apply
echo "a's change" >"$(home a)/src/sec/other"
on a publish
on b apply
assert_eq "a's change" "$(cat "$(home b)/src/sec/other" 2>/dev/null)" "b takes a's change"
assert_eq "b's key" "$(cat "$(home b)/src/sec/secrets/key.txt" 2>/dev/null)" "and keeps its own secrets dir"
assert_eq "no" "$([ -e "$(home a)/src/sec/secrets" ] && echo yes || echo no)" "which never reached a"
assert_eq "" "$(git -C "$GH/hub.git" ls-tree -r --name-only refs/srcsync/b/src/sec/tree 2>/dev/null | grep secrets)" \
	"or the hub"
github_repo wt a src/wt
on a publish
on b apply
g a src/wt worktree add -q -b spike "$(home a)/src/wt-spike"
on a publish
on b apply
on b publish
echo "b's secret" >"$(home b)/src/wt-spike/.env"
mkdir "$(home b)/src/wt-spike/sub"
echo "b's other secret" >"$(home b)/src/wt-spike/sub/.env"
mkdir "$(home b)/src/wt-spike/secrets"
echo "b's key" >"$(home b)/src/wt-spike/secrets/key.txt"
g a src/wt worktree remove --force "$(home a)/src/wt-spike"
on a publish
on b apply
kept=$(ls -d "$(home b)"/.local/state/srcsync/removed/src/wt-spike/*/ 2>/dev/null | head -1)
assert_eq "no" "$([ -e "$(home b)/src/wt-spike" ] && echo yes || echo no)" "the worktree goes"
assert_eq "b's secret" "$(cat "$kept/.env" 2>/dev/null)" "its .env is kept in b's state"
assert_eq "b's other secret" "$(cat "$kept/sub/.env" 2>/dev/null)" "at any depth"
assert_eq "b's key" "$(cat "$kept/secrets/key.txt" 2>/dev/null)" "and inside an excluded directory"
assert_eq 1 "$(grep -c 'src/wt-spike: kept 3 excluded files in' "$WORK/b.log")" "and b says where"

printf 'a followed removal whose excluded files cannot be saved\n'

g a src/wt worktree add -q -b two "$(home a)/src/wt-two"
on a publish
on b apply
on b publish
echo "b's secret" >"$(home b)/src/wt-two/.env"
g a src/wt worktree remove --force "$(home a)/src/wt-two"
on a publish
state_b=$(home b)/.local/state/srcsync
chmod 555 "$state_b/removed/src"
on b apply
chmod 755 "$state_b/removed/src"
assert_eq "b's secret" "$(cat "$(home b)/src/wt-two/.env" 2>/dev/null)" "an unwritable backup keeps the worktree"
assert_eq 1 "$(grep -c 'src/wt-two: could not save its excluded files; kept' "$WORK/b.log")" "and b says why"

# Nothing set up in advance makes ls-files fail once now_json has read the
# worktree, so this wraps git to fail the listing, as a crash or a mid-scan
# error would. The rest is the real cmd_apply.
lib b eval '
	git() { case "$*" in *ls-files*-o*) return 128 ;; esac; command git "$@"; }
	cmd_apply' 2>>"$WORK/b.log"
assert_eq "b's secret" "$(cat "$(home b)/src/wt-two/.env" 2>/dev/null)" "so does a failed listing"
assert_eq 2 "$(grep -c 'src/wt-two: could not save its excluded files; kept' "$WORK/b.log")" "and b says why"

on b apply
assert_eq "no" "$([ -e "$(home b)/src/wt-two" ] && echo yes || echo no)" "the next good run removes it"
assert_eq "b's secret" "$(cat "$state_b"/removed/src/wt-two/*/.env 2>/dev/null)" "after keeping the .env"

printf 'a tracked file an exclude matches\n'

# Excludes filter untracked files only. .env.example is committed in many
# repos, and an edit to it was once invisible, so apply overwrote it.
for m in a b; do printf 'exclude .env\nexclude .env.*\n' >"$(home $m)/.config/srcsync/config"; done
github_repo envx a src/envx
echo "API_URL=example" >"$(home a)/src/envx/.env.example"
g a src/envx add -f .env.example
g a src/envx commit -q -m "track env example"
g a src/envx push -q origin main
on a publish
on b apply
on b publish
on a apply
echo "LOCAL_ONLY=1" >>"$(home b)/src/envx/.env.example"
on b publish
echo "a's change" >>"$(home a)/src/envx/README"
on a publish
took=$(grep -c 'src/envx: took a' "$WORK/b.log")
on b apply
assert_eq "API_URL=example
LOCAL_ONLY=1" "$(cat "$(home b)/src/envx/.env.example")" "b's edit survives a's apply"
assert_eq "$took" "$(grep -c 'src/envx: took a' "$WORK/b.log")" "b does not take a's state over it"

synced envt
echo "API_URL=example" >"$(home a)/src/envt/.env.example"
g a src/envt add -f .env.example
g a src/envt commit -q -m "track env example"
on a publish
on b apply
on b publish
on a apply
echo "FROM_B=1" >>"$(home b)/src/envt/.env.example"
on b publish
on a apply
assert_eq "API_URL=example
FROM_B=1" "$(cat "$(home a)/src/envt/.env.example")" "the edit travels to a"

# A staged rename of a tracked excluded file reads as a rename, not an add,
# unless the drop step asks for no renames; the new name must not travel.
g a src/envt reset -q --hard
seq -f 'KEY%g=example' 20 >"$(home a)/src/envt/.env.example"
g a src/envt commit -q -am "longer env example"
g a src/envt mv .env.example .env.local
echo "SECRET=hunter2" >>"$(home a)/src/envt/.env.local"
T=$(lib a worktree_tree "$(home a)/src/envt")
assert_eq "" "$(git -C "$(home a)/src/envt" ls-tree --name-only "$T" .env.local)" \
	"a renamed-to excluded name stays out of the snapshot"
g a src/envt reset -q --hard

g a src/envx worktree add -q -b feat "$(home a)/src/envx-feat" main
on a publish
on b apply
on b publish
on a apply
echo "UNPUBLISHED=1" >>"$(home b)/src/envx-feat/.env.example"
g a src/envx worktree remove "$(home a)/src/envx-feat"
on a publish
on b apply
assert_eq "API_URL=example
UNPUBLISHED=1" "$(cat "$(home b)/src/envx-feat/.env.example" 2>/dev/null)" \
	"an unpublished edit keeps the worktree a removed"
assert_eq 1 "$(grep -c 'src/envx-feat: removed on a but changed here; kept' "$WORK/b.log")" "and b says why"

on b publish
g a src/envx worktree add -q -b feat2 "$(home a)/src/envx-f2" main
on a publish
on b apply
on b publish
on a apply
echo "PUBLISHED=1" >>"$(home b)/src/envx-f2/.env.example"
on b publish
g a src/envx worktree remove "$(home a)/src/envx-f2"
on a publish
on b apply
assert_eq "API_URL=example
PUBLISHED=1" "$(g b src/envx show refs/srcsync/b/src/envx-f2/tree:.env.example 2>/dev/null)" \
	"a published edit is in b's snapshot when the worktree goes"

done_testing
