#!/usr/bin/env bash
# A Stop hook fires after every Claude turn in one worktree. Snapshotting every
# repo under ~/src each time is wasteful, so publish and apply can be pointed
# at a single path: publish scopes to its repo, apply to its worktree, and
# both leave every other repo's state exactly as the last full run left it.
#
#   ./scoped.test.sh

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

machine a
machine b
github_repo app a src/app
github_repo lib a src/lib
on a publish
on b apply

printf 'scoped publish\n'

echo "a's app change" >>"$(home a)/src/app/README"
echo "a's lib change" >>"$(home a)/src/lib/README"
mkdir -p "$(home a)/src/app/sub"
lib_before=$(jq -c '.repos["src/lib"]' "$(home a)/.local/state/srcsync/last.json")
on a publish "$(home a)/src/app/sub"

assert_eq "refs/srcsync/a/src/app/tree" "$(refs_in hub | cut -d' ' -f2)" \
	"the hub gets a ref for the scoped repo only"
assert_eq "$lib_before" "$(jq -c '.repos["src/lib"]' "$(home a)/.local/state/srcsync/last.json")" \
	"the untouched repo's entry in last.json is unchanged"

printf 'an unsynced path\n'

on a publish /tmp
rc=$?
assert_eq 1 "$(grep -c '/tmp: not a synced repo' "$WORK/a.log")" \
	"publish on a path outside any repo says so"
assert_eq 0 "$rc" "and still exits 0"

printf 'scoped apply\n'

on a publish
on b apply "$(home b)/src/app"
assert_eq "a's app change" "$(tail -1 "$(home b)/src/app/README")" "b gets a's scoped app change"
assert_eq "no" "$(grep -q "a's lib change" "$(home b)/src/lib/README" && echo yes || echo no)" \
	"but not the untouched lib"
on b apply
assert_eq "a's lib change" "$(tail -1 "$(home b)/src/lib/README")" "a full apply picks up the rest"

printf 'scoped apply preserves other conflicts\n'

echo "a's conflicting change" >>"$(home a)/src/app/README"
echo "b's conflicting change" >>"$(home b)/src/app/README"
on a publish
on b publish
on b apply
assert_eq 1 "$(jq 'length' "$(home b)/.local/state/srcsync/conflicts.json")" \
	"a full apply records the conflict"

echo "a's second lib change" >>"$(home a)/src/lib/README"
on a publish
on b apply "$(home b)/src/lib"
assert_eq 1 "$(jq '[.[] | select(.worktree == "src/app")] | length' \
	"$(home b)/.local/state/srcsync/conflicts.json")" \
	"the src/app conflict survives a scoped apply of another repo"

printf 'scoped publish of a linked worktree\n'

g a src/app worktree add -q -b spike "$(home a)/src/app-wt"
echo "wip" >"$(home a)/src/app-wt/wip"
on a publish "$(home a)/src/app-wt"
assert_eq "true" "$(jq -r '.repos["src/app"].worktrees | has("src/app-wt")' \
	"$(home a)/.local/state/srcsync/last.json")" \
	"the linked worktree's entry lands under its repo"

done_testing
