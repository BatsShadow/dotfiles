#!/usr/bin/env bash
# The walk-away handoff, both ways. A works on an unpushed branch, with a local
# commit, an edit, a new file and a deletion, then walks away. B must come up
# with the same branch, the same HEAD and the same uncommitted changes, with
# the index left alone so nothing looks staged. Then B works and hands back.
# An excluded file such as .env stays where it was written, in both directions.
# A publish that loses a race to the hub pulls and pushes again in the same run,
# and a hub clone left mid-rebase or dirty is reset rather than left stuck.
#
#   ./handoff.test.sh

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

machine a
machine b
github_repo app a src/app
git clone -q "$GHURL/app.git" "$(home b)/src/app" 2>/dev/null

printf 'handoff a to b\n'

g a src/app switch -q -c feature
echo "local commit" >"$(home a)/src/app/committed"
g a src/app add committed
g a src/app commit -q -m "not pushed"
echo "edited" >>"$(home a)/src/app/README"
echo "new" >"$(home a)/src/app/untracked"
rm "$(home a)/src/app/committed"

on a publish
on b publish
on b apply

assert_eq "feature" "$(g b src/app branch --show-current)" "b is on a's branch"
assert_eq "$(g a src/app rev-parse HEAD)" "$(g b src/app rev-parse HEAD)" \
	"b's HEAD is a's unpushed commit"
assert_eq "$(changes a src/app)" "$(changes b src/app)" \
	"b has a's edit, new file and deletion"
assert_eq "" "$(g b src/app diff --cached --name-only)" "nothing is staged on b"
assert_eq "hello
edited" "$(cat "$(home b)/src/app/README")" "the edit's content arrived"

printf 'handoff b back to a\n'

on b publish
echo "from b" >"$(home b)/src/app/second"
on b publish
on a publish
on a apply
assert_eq "$(changes b src/app)" "$(changes a src/app)" "a has b's new file on top"
assert_eq "from b" "$(cat "$(home a)/src/app/second" 2>/dev/null)" "with b's content"

printf 'a round trip settles\n'

on a publish
on b apply
assert_eq 1 "$(grep -c "took a's state" "$WORK/b.log")" \
	"b took a's state once, and nothing from the round trip"
assert_eq "[]" "$(jq -c . "$(home b)/.local/state/srcsync/conflicts.json")" \
	"no conflict after a clean handoff"

printf 'secrets stay home\n'

echo "exclude .env" >"$(home a)/.config/srcsync/config"
echo "exclude .env" >"$(home b)/.config/srcsync/config"
echo "SECRET=a" >"$(home a)/src/app/.env"
echo "change" >>"$(home a)/src/app/README"
on a publish
on b apply
assert_eq "no" "$([ -e "$(home b)/src/app/.env" ] && echo yes || echo no)" \
	"an excluded file does not travel"
echo "SECRET=b" >"$(home b)/src/app/.env"
on b publish
echo "more" >>"$(home a)/src/app/README"
on a publish
on b apply
assert_eq "SECRET=b" "$(cat "$(home b)/src/app/.env" 2>/dev/null)" \
	"and an apply leaves the other machine's own copy alone"

printf 'both machines push to the hub at once\n'

# The hub's pre-receive lands another machine's publish on main once, between
# a's pull and a's push, the race two Stop hooks at once run into.
cat >"$GH/hub.git/hooks/pre-receive" <<EOF
#!/bin/bash
grep -q ' refs/heads/main\$' || exit 0
[ -e "$WORK/raced" ] && exit 0
touch "$WORK/raced"
env -i PATH="\$PATH" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$GIT_CONFIG_GLOBAL" /bin/bash -c '
	git clone -q "$GH/hub.git" "$WORK/racer" &&
	mkdir -p "$WORK/racer/machines" && echo "{}" >"$WORK/racer/machines/c.json" &&
	git -C "$WORK/racer" add machines && git -C "$WORK/racer" commit -q -m "publish c" &&
	git -C "$WORK/racer" push -q origin HEAD:main' >/dev/null 2>&1
exit 0
EOF
chmod +x "$GH/hub.git/hooks/pre-receive"
echo "raced" >>"$(home a)/src/app/README"
on a publish
rm "$GH/hub.git/hooks/pre-receive"
assert_eq yes "$([ -e "$WORK/raced" ] && echo yes || echo no)" "the other push landed first"
assert_eq "$(lib a worktree_tree "$(home a)/src/app")" \
	"$(git -C "$GH/hub.git" show main:machines/a.json | jq -r '.repos["src/app"].worktrees["src/app"].tree')" \
	"a's push still reaches the hub in the same run"
assert_eq "{}" "$(git -C "$GH/hub.git" show main:machines/c.json 2>/dev/null)" "on top of the other one"
assert_eq no "$([ -e "$(home a)/.local/state/srcsync/hub-pending" ] && echo yes || echo no)" \
	"and nothing is left for the next run"

printf 'a hub clone stuck mid-rebase\n'

# Two machines under one id rebase clashing commits to the same file, and a
# run stopped inside pull --rebase leaves the rebase open. Every run after
# said "cannot reach the hub". The clone holds nothing last.json cannot
# rebuild, so srcsync resets it.
hub_a=$(home a)/.local/state/srcsync/hub
git clone -q "$GH/hub.git" "$WORK/clasher"
echo '{"host":"a","clash":1}' >"$WORK/clasher/machines/a.json"
git -C "$WORK/clasher" commit -q -a -m "clash"
git -C "$WORK/clasher" push -q origin HEAD:main
echo '{"host":"a","clash":2}' >"$hub_a/machines/a.json"
git -C "$hub_a" commit -q -a -m "local clash"
git -C "$hub_a" pull -q --rebase origin main >/dev/null 2>&1
assert_eq yes "$([ -d "$hub_a/.git/rebase-merge" ] && echo yes || echo no)" "a's hub clone is mid-rebase"
echo "unstuck" >>"$(home a)/src/app/README"
on a publish
assert_eq "$(lib a worktree_tree "$(home a)/src/app")" \
	"$(git -C "$GH/hub.git" show main:machines/a.json | jq -r '.repos["src/app"].worktrees["src/app"].tree')" \
	"the next publish reaches the hub"
assert_eq no "$([ -d "$hub_a/.git/rebase-merge" ] && echo yes || echo no)" "with the rebase gone"

printf 'a hub clone with stray edits\n'

echo "junk" >"$hub_a/machines/b.json"
echo "stray" >"$hub_a/stray"
echo "again" >>"$(home a)/src/app/README"
on a publish
assert_eq "$(lib a worktree_tree "$(home a)/src/app")" \
	"$(git -C "$GH/hub.git" show main:machines/a.json | jq -r '.repos["src/app"].worktrees["src/app"].tree')" \
	"the next publish reaches the hub"
assert_eq "" "$(git -C "$hub_a" status --porcelain)" "and the clone is clean"

printf 'a race that clashes on this machine file\n'

# The retry's pull stops on the clash and resets the clone, which drops the
# commit holding a's file, so the retry must write it again.
cat >"$GH/hub.git/hooks/pre-receive" <<EOF
#!/bin/bash
grep -q ' refs/heads/main\$' || exit 0
[ -e "$WORK/clashed" ] && exit 0
touch "$WORK/clashed"
env -i PATH="\$PATH" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$GIT_CONFIG_GLOBAL" /bin/bash -c '
	git clone -q "$GH/hub.git" "$WORK/clash-racer" &&
	echo "{\"host\":\"a\",\"clash\":3}" >"$WORK/clash-racer/machines/a.json" &&
	git -C "$WORK/clash-racer" commit -q -a -m "clash" &&
	git -C "$WORK/clash-racer" push -q origin HEAD:main' >/dev/null 2>&1
exit 0
EOF
chmod +x "$GH/hub.git/hooks/pre-receive"
echo "clash race" >>"$(home a)/src/app/README"
on a publish
rm "$GH/hub.git/hooks/pre-receive"
assert_eq yes "$([ -e "$WORK/clashed" ] && echo yes || echo no)" "the clashing push landed first"
assert_eq "$(lib a worktree_tree "$(home a)/src/app")" \
	"$(git -C "$GH/hub.git" show main:machines/a.json | jq -r '.repos["src/app"].worktrees["src/app"].tree')" \
	"a's file still reaches the hub in the same run"

printf 'a hub that has gone away\n'

# ls-remote failing was read as "no main yet", so the run went on from the
# clone's stale copy and a publish tried three pushes.
mv "$GH/hub.git" "$GH/hub.gone"
: >"$WORK/b.log"
on b apply
assert_eq 1 "$(grep -c 'cannot reach the hub' "$WORK/b.log")" "apply says it cannot reach the hub"
mv "$GH/hub.gone" "$GH/hub.git"

printf 'a repo tracked for its changes stays tracked\n'

# Someone else's clone, tracked only because a has a change in it. Once a
# throws the change away it must stay tracked: dropped, b's copy of the change
# would read as new work on a and come back.
git config --global --add url."$GH/".insteadOf git@github.com:other/
git init -q --bare "$GH/lent.git"
git clone -q git@github.com:other/lent.git "$(home a)/src/lent" 2>/dev/null
echo "hello" >"$(home a)/src/lent/README"
g a src/lent add README
g a src/lent commit -q -m "first"
g a src/lent push -q origin main
git clone -q git@github.com:other/lent.git "$(home b)/src/lent" 2>/dev/null
echo "wip" >>"$(home a)/src/lent/README"
on a publish
on b publish
on b apply
assert_eq " M README" "$(changes b src/lent)" "b takes a's change to an unowned repo"
g a src/lent checkout -q -- README
for _ in 1 2; do
	on a publish
	on b publish
	on a apply
	on b apply
done
assert_eq "" "$(changes a src/lent)" "a's discarded change does not come back"
assert_eq "" "$(changes b src/lent)" "and b drops it too"

# The same, but a drops origin as well, so the forge rule alone would ignore
# the repo. A published repo stays tracked whatever its remotes say.
git init -q --bare "$GH/lent2.git"
git clone -q git@github.com:other/lent2.git "$(home a)/src/lent2" 2>/dev/null
echo "hello" >"$(home a)/src/lent2/README"
g a src/lent2 add README
g a src/lent2 commit -q -m "first"
g a src/lent2 push -q origin main
git clone -q git@github.com:other/lent2.git "$(home b)/src/lent2" 2>/dev/null
echo "wip" >>"$(home a)/src/lent2/README"
on a publish
on b publish
on b apply
assert_eq " M README" "$(changes b src/lent2)" "b takes a's change"
g a src/lent2 checkout -q -- README
g a src/lent2 remote remove origin
for _ in 1 2; do
	on a publish
	on b publish
	on a apply
	on b apply
done
assert_eq "" "$(changes a src/lent2)" "a's discarded change does not come back once origin is gone"

done_testing
