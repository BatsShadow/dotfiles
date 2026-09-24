#!/usr/bin/env bash
# Worktrees and repos come and go on one machine, and the other follows: a new
# linked worktree appears at the same path, a removed one disappears, and a new
# repo is cloned, or built from the hub when it has no remote at all. A repo's
# main worktree is never removed, since that would be deleting the repo.
#
#   ./worktrees.test.sh

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

machine a
machine b
github_repo app a src/app
on a publish
on b apply

printf 'a new linked worktree\n'

g a src/app worktree add -q -b spike "$(home a)/src/app-spike"
echo "wip" >"$(home a)/src/app-spike/wip"
on a publish
on b apply
assert_eq "spike" "$(g b src/app-spike branch --show-current 2>/dev/null)" \
	"it appears on b, on its branch"
assert_eq "wip" "$(cat "$(home b)/src/app-spike/wip" 2>/dev/null)" "with its uncommitted file"
assert_eq "$(home b)/src/app-spike" \
	"$(g b src/app worktree list --porcelain | awk '/^worktree .*spike/ { print $2 }')" \
	"as a worktree of b's repo, not a copy"

printf 'a removed linked worktree\n'

on b publish
g a src/app worktree remove --force "$(home a)/src/app-spike"
on a publish
on b apply
assert_eq "no" "$([ -e "$(home b)/src/app-spike" ] && echo yes || echo no)" "it disappears from b"
assert_eq "spike" "$(g b src/app branch --list spike --format='%(refname:short)')" \
	"its branch stays for worktree-remove.sh to judge"

printf 'a removed linked worktree that b changed\n'

g a src/app worktree add -q -b keep "$(home a)/src/app-keep"
on a publish
on b apply
on b publish
echo "b's work" >"$(home b)/src/app-keep/mine"
g a src/app worktree remove --force "$(home a)/src/app-keep"
on a publish
on b apply
assert_eq "b's work" "$(cat "$(home b)/src/app-keep/mine" 2>/dev/null)" "it stays on b"

printf 'new repos\n'

github_repo lib a src/lib
git init -q "$(home a)/src/notes"
echo "private" >"$(home a)/src/notes/todo"
g a src/notes add todo
g a src/notes commit -q -m "notes"
echo "sync src/notes hub" >>"$(home a)/.config/srcsync/config"
on a publish
on b apply
assert_eq "$GH/lib.git" "$(g b src/lib remote get-url origin 2>/dev/null)" \
	"a repo with a remote is cloned from it"
assert_eq "private" "$(cat "$(home b)/src/notes/todo" 2>/dev/null)" \
	"a repo with no remote is built from the hub"
assert_eq "$(g a src/notes rev-parse HEAD)" "$(g b src/notes rev-parse HEAD 2>/dev/null)" \
	"with its history"

printf 'a removed repo\n'

rm -rf "$(home a)/src/lib"
on a publish
on b apply
assert_eq "yes" "$([ -d "$(home b)/src/lib/.git" ] && echo yes || echo no)" \
	"a repo deleted on a is not deleted on b"

done_testing
