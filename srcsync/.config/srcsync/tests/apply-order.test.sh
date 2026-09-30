#!/usr/bin/env bash
# A full apply takes the other machine's worktrees newest first across repos,
# as publish does, so the work the user just left lands first. Removals still
# come after every add. A repo this machine lacks is cloned through its main
# worktree first, whatever the order, since a linked worktree needs the repo.
#
#   ./apply-order.test.sh

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

machine a
machine b
github_repo app a src/app
github_repo lib a src/lib
g a src/app worktree add -q -b spike "$(home a)/src/app-wt"
g a src/app worktree add -q -b old "$(home a)/src/app-old"
git clone -q "$GHURL/app.git" "$(home b)/src/app" 2>/dev/null
git clone -q "$GHURL/lib.git" "$(home b)/src/lib" 2>/dev/null
on a publish
on b publish
on b apply
on b publish

# The worktrees b took from a, in the order it took them.
took() { sed -n "s#^srcsync: \(.*\): took a's state\$#\1#p" "$WORK/b.log" | tr '\n' ' '; }

printf 'newest first, across repos\n'

echo "app" >>"$(home a)/src/app/README"
on a publish
sleep 1
echo "lib" >>"$(home a)/src/lib/README"
on a publish
sleep 1
echo "app-wt" >>"$(home a)/src/app-wt/README"
g a src/app worktree remove --force "$(home a)/src/app-old"
on a publish
: >"$WORK/b.log"
on b apply
assert_eq "src/app-wt src/lib src/app " "$(took)" "b takes a's worktrees newest first"
assert_eq "no" "$([ -e "$(home b)/src/app-old" ] && echo yes || echo no)" "and the removal after them"

printf 'a missing repo is cloned through its main worktree\n'

# No remote: b can only build it from the hub, so a linked worktree taken
# first would leave the main worktree with no commits, unreadable for good.
mkdir -p "$(home a)/src/solo"
git -C "$(home a)/src/solo" init -q
echo "solo" >"$(home a)/src/solo/README"
g a src/solo add README
g a src/solo commit -q -m first
echo "sync src/solo hub" >>"$(home a)/.config/srcsync/config"
on a publish
sleep 1
g a src/solo worktree add -q -b side "$(home a)/src/solo-wt"
echo "side" >>"$(home a)/src/solo-wt/README"
on a publish
: >"$WORK/b.log"
on b apply
assert_eq "src/solo src/solo-wt " "$(took)" "the main worktree comes first"
assert_eq "solo" "$(cat "$(home b)/src/solo/README")" "and is applied"
assert_eq "solo
side" "$(cat "$(home b)/src/solo-wt/README" 2>/dev/null)" "as is the linked one"

done_testing
