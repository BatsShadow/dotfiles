#!/usr/bin/env bash
# Where snapshots go, and what never goes anywhere. Company code reaches only
# the repo's own origin, whatever the config says, because a mistake there puts
# it on a personal account. A push over the size cap is refused. And a run with
# nothing new pushes nothing, since it happens every few minutes.
#
#   ./routing.test.sh

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

machine a
machine b
cat >"$(home a)/.config/srcsync/config" <<'CFG'
company acme
company upngo
team acme-team
exclude .env
sync src/work hub
CFG

printf 'company repos\n'

git init -q --bare "$GH/acme-fork.git"
github_repo work a src/work
g a src/work remote set-url origin "$GHURL/acme-fork.git"
g a src/work push -q origin main
echo "wip" >>"$(home a)/src/work/README"
on a publish
assert_eq "" "$(refs_in hub)" "a company repo sends nothing to the hub, despite the override"
assert_eq "refs/srcsync/a/src/work/tree" "$(refs_in acme-fork | cut -d' ' -f2)" \
	"its snapshot goes to its own origin"

git init -q --bare "$GH/acme-team.git"
github_repo shared a src/shared
g a src/shared remote set-url origin "$GHURL/acme-team.git"
echo "wip" >>"$(home a)/src/shared/README"
on a publish
assert_eq "" "$(refs_in acme-team)" "a company repo whose origin is the team repo is not synced"
assert_eq 1 "$(grep -c 'src/shared origin is the team repo, fork it first' "$WORK/a.log")" \
	"and the reason is reported"
assert_eq "null" "$(jq -c '.repos["src/shared"]' "$(home a)/.local/state/srcsync/last.json")" \
	"and it is left out of the state file"

# GitHub owner names ignore case, so UpNGo clones as well as upngo. A miss
# would send the repo's whole history to the personal hub.
git init -q --bare "$GH/UpNGo-app.git"
github_repo mixed a src/mixed
g a src/mixed remote set-url origin "$GHURL/UpNGo-app.git"
g a src/mixed push -q origin main
echo "wip" >>"$(home a)/src/mixed/README"
on a publish
assert_eq "" "$(refs_in hub | grep src/mixed)" "a company match ignores case"
assert_eq "refs/srcsync/a/src/mixed/tree" "$(refs_in UpNGo-app | cut -d' ' -f2)" \
	"and the snapshot goes to its origin"

printf 'what gets pushed\n'

github_repo clean a src/clean
on a publish
assert_eq "null" "$(jq -r '.repos["src/clean"].worktrees["src/clean"].snapshot' \
	"$(home a)/.local/state/srcsync/last.json")" "a clean worktree already on its remote needs no snapshot"
assert_eq "" "$(refs_in hub | grep src/clean)" "so none is pushed"

hub_before=$(git -C "$GH/hub.git" rev-parse main)
refs_before=$(refs_in hub; refs_in acme-fork)
on a publish
assert_eq "$hub_before" "$(git -C "$GH/hub.git" rev-parse main)" "an unchanged run leaves the state file alone"
assert_eq "$refs_before" "$(refs_in hub; refs_in acme-fork)" "and pushes no snapshot"

printf 'size\n'

echo "max_size 20K" >>"$(home a)/.config/srcsync/config"
head -c 100000 /dev/urandom >"$(home a)/src/clean/blob"
on a publish
assert_eq 1 "$(grep -c 'src/clean snapshot is .* over the .* cap; not published' "$WORK/a.log")" \
	"a snapshot over the cap is refused and reported"
blob=$(git hash-object "$(home a)/src/clean/blob")
assert_eq "no" "$(git -C "$GH/hub.git" cat-file -e "$blob" 2>/dev/null && echo yes || echo no)" \
	"and does not reach the hub"

printf 'the lock\n'

mkdir -p "$(home a)/.local/state/srcsync/lock"
sleep 30 &
echo $! >"$(home a)/.local/state/srcsync/lock/pid"
on a publish
assert_eq 1 "$(grep -c 'another run holds the lock' "$WORK/a.log")" "a held lock stops a second run"
kill $!
wait $! 2>/dev/null
on a publish
assert_eq 1 "$(grep -c 'another run holds the lock' "$WORK/a.log")" "a dead holder's lock is taken over"
assert_eq "no" "$([ -e "$(home a)/.local/state/srcsync/lock" ] && echo yes || echo no)" \
	"and released at the end"

printf 'failures\n'

github_repo broken a src/broken
echo "wip" >>"$(home a)/src/broken/README"
on a publish
entry=$(jq -c '.repos["src/broken"].worktrees["src/broken"]' "$(home a)/.local/state/srcsync/last.json")
success_at=$(cat "$(home a)/.local/state/srcsync/last-success")
echo "more wip" >>"$(home a)/src/broken/README"
chmod -R a-w "$(home a)/src/broken/.git/objects"
sleep 1
on a publish
chmod -R u+w "$(home a)/src/broken/.git/objects"
assert_eq "$entry" "$(jq -c '.repos["src/broken"].worktrees["src/broken"]' "$(home a)/.local/state/srcsync/last.json")" \
	"a failed snapshot leaves the worktree unchanged"
assert_eq "false" "$(jq -r '.repos["src/broken"].removed | has("src/broken")' "$(home a)/.local/state/srcsync/last.json")" \
	"and the worktree does not appear in removed"
assert_eq "$success_at" "$(cat "$(home a)/.local/state/srcsync/last-success")" \
	"and last-success is unchanged"
assert_eq 1 "$(grep -c 'keeping the last publish' "$WORK/a.log")" \
	"and the reason is in the log"

echo src/gone >>"$(home a)/.local/state/srcsync/pending"
on a publish
assert_eq "no" "$(grep -q src/gone "$(home a)/.local/state/srcsync/pending" && echo yes || echo no)" \
	"a gone repo is dropped from pending"

printf 'which repos are tracked\n'

# Machine c routes by forge and owner. Its repos' origins name GitHub, an ssh
# alias for it, or Bitbucket, and the test gitconfig sends each to $GH.
machine c
cat >"$(home c)/.config/srcsync/config" <<'CFG'
company acme
team acme-team
forge github.com
owner Me
sync src/bare hub
sync src/held skip
CFG
for u in git@github.com:other/ git@github.com-batsshadow:ME/ ssh://git@github.com/me/ \
	https://github.com/other/ git@github.com:/me/ git@bitbucket.org:other/ git@bitbucket.org:acme/ \
	git@github.com:acme-team/; do
	git config --global --add url."$GH/".insteadOf "$u"
done
C_LAST=$(home c)/.local/state/srcsync/last.json

# A repo with one pushed commit on c at ~/$2, cloned from $1, whose last path
# part names the bare repo in $GH.
c_repo() { # url path
	local b=${1##*/}
	git init -q --bare "$GH/$b"
	git clone -q "$1" "$(home c)/$2" 2>/dev/null
	echo "hello" >"$(home c)/$2/README"
	g c "$2" add README
	g c "$2" commit -q -m "first"
	g c "$2" push -q origin main
}
tracked() { jq -r --arg r "$1" 'if .repos[$r] then "tracked" else "ignored" end' "$C_LAST"; }
said() { grep -c "$1" "$WORK/c.log"; }

c_repo git@bitbucket.org:other/bb.git src/bb
echo "wip" >>"$(home c)/src/bb/README"
git init -q "$(home c)/src/loose"
echo "wip" >"$(home c)/src/loose/notes"
g c src/loose add notes
g c src/loose commit -q -m "first"
echo "more" >>"$(home c)/src/loose/notes"
git init -q "$(home c)/src/bare"
echo "wip" >"$(home c)/src/bare/notes"
g c src/bare add notes
g c src/bare commit -q -m "first"
c_repo git@github.com:me/owned.git src/owned
c_repo git@github.com-batsshadow:ME/alias.git src/alias
c_repo ssh://git@github.com/me/sshurl.git src/sshurl
c_repo git@github.com:/me/slash.git src/slash
c_repo https://github.com/other/theirs.git src/theirs
c_repo git@github.com:other/dirty.git src/dirty
echo "new" >"$(home c)/src/dirty/untracked"
c_repo git@github.com:other/ahead.git src/ahead
echo "local" >"$(home c)/src/ahead/local"
g c src/ahead add local
g c src/ahead commit -q -m "not pushed"
c_repo git@github.com:other/ignoredonly.git src/ignoredonly
echo "junk" >"$(home c)/src/ignoredonly/.gitignore"
g c src/ignoredonly add .gitignore
g c src/ignoredonly commit -q -m "ignore junk"
g c src/ignoredonly push -q origin main
echo "x" >"$(home c)/src/ignoredonly/junk"
c_repo git@github.com:other/wt.git src/wt
g c src/wt worktree add -q "$(home c)/src/wt-side" -b side
echo "side" >"$(home c)/src/wt-side/side"
c_repo git@bitbucket.org:acme/acme-order.git src/order
echo "wip" >>"$(home c)/src/order/README"
c_repo git@github.com:acme-team/acme-shared.git src/cshared
echo "wip" >>"$(home c)/src/cshared/README"
c_repo git@github.com:other/held.git src/held
echo "wip" >>"$(home c)/src/held/README"
c_repo git@github.com:me/acme-cfork.git src/cfork
echo "wip" >>"$(home c)/src/cfork/README"
on c publish

assert_eq ignored "$(tracked src/held)" "a sync line saying skip holds back a dirty repo"
assert_eq 0 "$(said src/held)" "and says nothing, since the config already says why"
assert_eq ignored "$(tracked src/bb)" "a repo whose origin is on Bitbucket is ignored, dirty or not"
assert_eq ignored "$(tracked src/loose)" "a repo with no remote is ignored"
assert_eq tracked "$(tracked src/bare)" "unless a sync line sends it to the hub"
assert_eq "refs/srcsync/c/src/bare/tree" "$(refs_in hub | grep src/bare | cut -d' ' -f2)" \
	"and its snapshot goes there"
assert_eq tracked "$(tracked src/owned)" "a clean repo on an owned account is tracked"
assert_eq tracked "$(tracked src/alias)" "an ssh alias counts as GitHub, and the owner match ignores case"
assert_eq tracked "$(tracked src/sshurl)" "an ssh:// URL counts as GitHub"
assert_eq tracked "$(tracked src/slash)" "an owner after a leading slash still counts"
assert_eq ignored "$(tracked src/theirs)" "a clean repo someone else owns is ignored"
assert_eq tracked "$(tracked src/dirty)" "one with an untracked file is tracked"
assert_eq tracked "$(tracked src/ahead)" "one with a commit no remote has is tracked"
assert_eq ignored "$(tracked src/ignoredonly)" "an ignored file is not a local change"
assert_eq tracked "$(tracked src/wt)" "a change in any worktree counts"
assert_eq 0 "$(said 'src/bb\|src/loose\|src/theirs\|src/ignoredonly')" "ignoring a repo says nothing"

assert_eq ignored "$(tracked src/order)" "a company repo on Bitbucket is not synced"
assert_eq 0 "$(said 'src/order')" "and says nothing, like any repo off GitHub"
assert_eq "" "$(refs_in acme-order)" "and nothing is pushed to it"
assert_eq 1 "$(said 'src/cshared origin is the team repo, fork it first')" \
	"a company repo whose origin is the team repo is still skipped"
assert_eq "refs/srcsync/c/src/cfork/tree" "$(refs_in acme-cfork | cut -d' ' -f2)" \
	"a company fork on GitHub still gets its snapshot"
assert_eq "" "$(refs_in hub | grep 'src/order\|src/cshared\|src/cfork')" "and no company repo reaches the hub"

rm "$(home c)/src/dirty/untracked"
on c publish
assert_eq tracked "$(tracked src/dirty)" "a repo published before stays tracked once clean"

printf 'forge, owner and company edge cases\n'

for u in git@github.company.com:me/ git@github.com.evil.io:me/ git@mygithub.com:me/ \
	https://github.com/me/ git@github.com:meh/ git@github.com:acme/ git@bitbucket.org:me/; do
	git config --global --add url."$GH/".insteadOf "$u"
done
c_repo git@github.company.com:me/corp.git src/corp
c_repo git@github.com.evil.io:me/evil.git src/evil
c_repo git@mygithub.com:me/mygh.git src/mygh
c_repo https://github.com/me/owned-https.git src/owned-https
c_repo git@github.com:meh/meh.git src/meh
c_repo git@github.com:other/upstream.git src/upstream
git init -q --bare "$GH/upstream-mine.git"
g c src/upstream remote add mine git@github.com:me/upstream-mine.git
g c src/upstream fetch -q origin
c_repo git@bitbucket.org:other/bbfork.git src/bbfork
git init -q --bare "$GH/bbfork-mine.git"
g c src/bbfork remote add mine git@github.com:me/bbfork-mine.git
# Only the configured URL names the company: insteadOf rewrites it to a path
# under $GH, which does not.
c_repo git@github.com:acme/plain.git src/plain
echo "wip" >>"$(home c)/src/plain/README"
# A queued push for a repo that is ignored by the time it runs.
c_repo git@github.com:other/queued.git src/queued
g c src/queued update-ref refs/srcsync/c/src/queued/tree HEAD
echo src/queued >>"$(home c)/.local/state/srcsync/pending"
on c publish

assert_eq ignored "$(tracked src/corp)" "github.company.com is not github.com"
assert_eq ignored "$(tracked src/evil)" "nor is github.com.evil.io"
assert_eq ignored "$(tracked src/mygh)" "nor mygithub.com"
assert_eq tracked "$(tracked src/owned-https)" "an owned https URL is tracked"
assert_eq ignored "$(tracked src/meh)" "an owner matches whole, so meh is not me"
assert_eq tracked "$(tracked src/upstream)" "an owned remote besides origin makes a clean clone tracked"
assert_eq ignored "$(tracked src/bbfork)" "but not when origin is off GitHub"
assert_eq "refs/srcsync/c/src/plain/tree" "$(refs_in plain | cut -d' ' -f2)" \
	"a company match on the configured URL alone sends it to origin"
assert_eq "" "$(refs_in hub | grep src/plain)" "and never to the hub"
assert_eq "" "$(refs_in queued; refs_in hub | grep src/queued)" "a queued push for an ignored repo is not made"

done_testing
