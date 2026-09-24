#!/usr/bin/env bash
# Each publish writes a whole new blob for every grown transcript and changed
# untracked file, and moving a srcsync ref leaves the old one unreachable.
# gc --auto counts loose objects, not bytes, so it never ran: 100 appends to
# an 8.4 MB transcript took .git/objects from 6 MB to 605 MB. The timer
# repacks a repo at most once a day, and only one with loose objects to spare.
# What any ref or reflog reaches stays, and so does anything unreachable
# younger than a day.
#
#   ./maintain.test.sh

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

machine a
printf 'auto on\ntranscripts on\n' >"$(home a)/.config/srcsync/config"
github_repo app a src/app
repo=$(home a)/src/app
log=$(home a)/.local/state/srcsync/auto.log
P=$(home a)/.claude/projects/$(printf '%s' "$repo" | tr -c 'A-Za-z0-9' '-')
mkdir -p "$P"
head -c 300000 /dev/urandom | base64 >"$P/s1.jsonl"

loose() { git -C "$repo" count-objects -v | awk '/^count:/ { print $2 }'; }
repacks() { grep -c 'src/app: repacked' "$log" 2>/dev/null; }
has() { git -C "$repo" cat-file -e "$1" 2>/dev/null && echo yes || echo no; }

on a publish
for i in 1 2 3 4 5; do
	echo "{\"turn\":$i}" >>"$P/s1.jsonl"
	on a auto stop "$repo"
done

# One commit only a reflog reaches, one unreachable blob two days old, one
# unreachable blob written just now.
c1=$(git -C "$repo" commit-tree -m one "$(git -C "$repo" rev-parse 'HEAD^{tree}')")
c2=$(git -C "$repo" commit-tree -m two "$(git -C "$repo" rev-parse 'HEAD^{tree}')")
git -C "$repo" update-ref --create-reflog refs/test/kept "$c1"
git -C "$repo" update-ref refs/test/kept "$c2"
old=$(echo "old garbage" | git -C "$repo" hash-object -w --stdin)
touch -t "$(date -v-2d +%Y%m%d%H%M)" "$repo/.git/objects/${old:0:2}/${old:2}"
fresh=$(echo "fresh garbage" | git -C "$repo" hash-object -w --stdin)
claude_tree=$(git -C "$repo" rev-parse 'refs/srcsync/a/src/app/claude^{tree}')

printf 'the Stop hook never repacks\n'

n=$(loose)
assert_eq 0 "$(repacks)" "five publishes repack nothing"
assert_eq yes "$([ "$n" -gt 10 ] && echo yes || echo no)" "and leave their objects loose"

printf 'a repo with little loose is left alone\n'

on a auto timer
assert_eq 0 "$(repacks)" "under the loose threshold the timer repacks nothing"

printf 'the timer repacks once a day\n'

SRCSYNC_REPACK_LOOSE_KB=0 on a auto timer
assert_eq 1 "$(repacks)" "the timer repacks and logs it"
assert_eq 0 "$(loose)" "no loose objects are left"
assert_eq yes "$(has "$claude_tree")" "the transcripts' tree stays"
assert_eq yes "$(has "$c1")" "a commit only a reflog reaches stays"
assert_eq yes "$(has "$fresh")" "an unreachable object from today stays"
assert_eq no "$(has "$old")" "an unreachable object two days old goes"
git -C "$repo" fsck --connectivity-only --no-dangling >/dev/null 2>&1
assert_eq 0 "$?" "and the repo is whole"

echo "{\"turn\":6}" >>"$P/s1.jsonl"
SRCSYNC_REPACK_LOOSE_KB=0 on a auto timer
assert_eq 1 "$(repacks)" "a second timer the same day does not repack"

touch -t "$(date -v-2d +%Y%m%d%H%M)" "$(home a)/.local/state/srcsync/repacked/src%2Fapp"
SRCSYNC_REPACK_LOOSE_KB=0 on a auto timer
assert_eq 2 "$(repacks)" "a day later it does"

printf "a cruft pack git gc wrote is not srcsync's to expire\n"
github_repo app2 a src/app2
r2=$(home a)/src/app2
echo "gc garbage" | git -C "$r2" hash-object -w --stdin >/dev/null
git -C "$r2" gc -q --cruft --prune=2.weeks.ago
assert_eq yes "$(ls "$r2"/.git/objects/pack/*.mtimes >/dev/null 2>&1 && echo yes || echo no)" "git gc left a cruft pack"
on a auto timer
assert_eq 0 "$(grep -c 'src/app2: repacked' "$log" 2>/dev/null)" "the timer leaves that repo alone"

done_testing
