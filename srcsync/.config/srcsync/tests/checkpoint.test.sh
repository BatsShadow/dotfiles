#!/usr/bin/env bash
# A full publish takes minutes, and a run cut short, by the lid closing or the
# network dropping, used to make none of its work visible. So once it has
# visited every worktree touched since the last good run, it pushes and writes
# the hub file, then carries on. That checkpoint must never read as a removal
# or a change to anything it has not visited yet.
#
#   ./checkpoint.test.sh

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Sets the mtime of a worktree's git file, index or logs/HEAD, to $4.
stamp() { # machine dir git-path touch-time
	touch -t "$4" "$(g "$1" "$2" rev-parse --path-format=absolute --git-path "$3")"
}

# The worktrees a machine's file lists besides src/app-wt, removed included.
others() { jq -c '.repos | del(.["src/app"].worktrees["src/app-wt"])' "$@"; }

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
# a removal already published, which the checkpoint must carry as it is
g a src/app worktree remove --force "$(home a)/src/app-old"
on a publish
on b apply

printf 'a run stopped at the checkpoint\n'

# a has edited three worktrees since its last run but touched only one, as
# when the user edits files by hand in one and Claude works in another.
echo "a app" >>"$(home a)/src/app/README"
echo "a app-wt" >>"$(home a)/src/app-wt/README"
echo "a lib" >>"$(home a)/src/lib/README"
for d in src/app src/app-wt src/lib; do
	stamp a $d index 202001010000
	stamp a $d logs/HEAD 202001010000
done
state_a=$(home a)/.local/state/srcsync
state_b=$(home b)/.local/state/srcsync
echo "2021-01-01T00:00:00Z" >"$state_a/last-full"
touch "$(g a src/app-wt rev-parse --path-format=absolute --git-path index)"
hub_before=$(git -C "$GH/hub.git" show main:machines/a.json)
last_before=$(cat "$state_a/last.json")
b_app=$(cat "$(home b)/src/app/README")
b_lib=$(cat "$(home b)/src/lib/README")
b_last=$(others "$state_b/last.json")

SRCSYNC_STOP_AFTER_CHECKPOINT=1 on a publish
hub_now=$(git -C "$GH/hub.git" show main:machines/a.json)
assert_eq "$last_before" "$(cat "$state_a/last.json")" "the stopped run leaves last.json alone"
assert_eq yes "$([ "$(jq -c '.repos["src/app"].worktrees["src/app-wt"]' <<<"$hub_now")" != \
	"$(jq -c '.repos["src/app"].worktrees["src/app-wt"]' <<<"$hub_before")" ] && echo yes || echo no)" \
	"but the hub has the recent worktree's new state"
assert_eq "$(others <<<"$hub_before")" "$(others <<<"$hub_now")" \
	"and every other entry as before, removed included"
assert_eq '{"src/app-old"' "$(jq -c '.repos["src/app"].removed' <<<"$hub_now" | cut -d: -f1)" \
	"which still holds the earlier removal"

on b apply
assert_eq "a app-wt" "$(tail -1 "$(home b)/src/app-wt/README")" "b takes the recent worktree"
assert_eq "$b_app" "$(cat "$(home b)/src/app/README")" "and leaves the older app worktree as it was"
assert_eq "$b_lib" "$(cat "$(home b)/src/lib/README")" "and the older lib"
assert_eq "$b_last" "$(others "$state_b/last.json")" "and records nothing new for them"
assert_eq "" "$(jq -r '.[].worktree' "$state_b/conflicts.json")" "with no conflict"

on a publish
on b apply
assert_eq "a app|a lib" "$(tail -1 "$(home b)/src/app/README")|$(tail -1 "$(home b)/src/lib/README")" \
	"the next full run carries the rest"

printf 'no checkpoint when every worktree or none is recent\n'

# The value of the snapshot a's last.json records for src/lib, last line.
lib_snapshot() {
	g a src/lib show "$(jq -r '.repos["src/lib"].worktrees["src/lib"].snapshot' "$state_a/last.json"):README" | tail -1
}
rm -f "$state_a/last-full"
echo "a again" >>"$(home a)/src/lib/README"
SRCSYNC_STOP_AFTER_CHECKPOINT=1 on a publish
assert_eq "a again" "$(lib_snapshot)" \
	"with no last full run, every worktree is recent and the run goes to the end"
echo "2999-01-01T00:00:00Z" >"$state_a/last-full"
echo "a once more" >>"$(home a)/src/lib/README"
SRCSYNC_STOP_AFTER_CHECKPOINT=1 on a publish
assert_eq "a once more" "$(lib_snapshot)" "and so does a run with nothing recent"

printf 'a hook run does not move the cutoff\n'

# lib is edited after the last full run, then a Stop hook publishes app-wt
# alone. lib is still unpublished, so the next full run's checkpoint must
# include it, though the hook's run succeeded after lib was touched.
on a publish
on b apply
for d in src/app src/app-wt src/lib; do
	stamp a $d index 202001010000
	stamp a $d logs/HEAD 202001010000
done
sleep 1
echo "a lib after the full run" >>"$(home a)/src/lib/README"
touch "$(g a src/lib rev-parse --path-format=absolute --git-path index)"
sleep 1
echo "auto on" >>"$(home a)/.config/srcsync/config"
echo "a app-wt by hook" >>"$(home a)/src/app-wt/README"
on a auto stop "$(home a)/src/app-wt"
sleep 1
echo "a app-wt again" >>"$(home a)/src/app-wt/README"
touch "$(g a src/app-wt rev-parse --path-format=absolute --git-path index)"
echo "a app, not recent" >>"$(home a)/src/app/README"
b_app=$(cat "$(home b)/src/app/README")
SRCSYNC_STOP_AFTER_CHECKPOINT=1 on a publish
on b apply
assert_eq "a lib after the full run" "$(tail -1 "$(home b)/src/lib/README")" \
	"the checkpoint carries a worktree touched before the hook ran"
assert_eq "a app-wt again" "$(tail -1 "$(home b)/src/app-wt/README")" "and the one touched after"
assert_eq "$b_app" "$(cat "$(home b)/src/app/README")" "but not the one untouched since the full run"

printf 'a run that dies after its checkpoint\n'

# The checkpoint put app's edit on the hub, the run died, and the edit was
# thrown away. last.json never saw the edit, so the next run finds nothing
# new, but the hub must not keep what a no longer has.
on a publish
on b apply
for d in src/app src/app-wt src/lib; do
	stamp a $d index 202001010000
	stamp a $d logs/HEAD 202001010000
done
cp "$(home a)/src/app/README" "$WORK/app-readme"
echo "a thrown away" >>"$(home a)/src/app/README"
echo "2021-01-01T00:00:00Z" >"$state_a/last-full"
touch "$(g a src/app rev-parse --path-format=absolute --git-path index)"
SRCSYNC_STOP_AFTER_CHECKPOINT=1 on a publish
assert_eq "a thrown away" "$(git -C "$GH/hub.git" show main:machines/a.json |
	jq -r '.repos["src/app"].worktrees["src/app"].snapshot' | xargs -I{} git -C "$(home a)/src/app" show {}:README | tail -1)" \
	"the checkpoint carried the edit"
cp "$WORK/app-readme" "$(home a)/src/app/README"
on a publish
assert_eq "$(jq -c '.repos' "$state_a/last.json")" "$(git -C "$GH/hub.git" show main:machines/a.json | jq -c .repos)" \
	"the next run puts the hub back to last.json"

printf 'a repo new since the last publish waits for the end\n'

# Only its linked worktree is recent. Laid alone into the checkpoint, a
# hub-only repo would reach b without its main worktree.
mkdir -p "$(home a)/src/solo"
git -C "$(home a)/src/solo" init -q
echo "solo" >"$(home a)/src/solo/README"
g a src/solo add README
g a src/solo commit -q -m first
g a src/solo worktree add -q -b side "$(home a)/src/solo-wt"
echo "sync src/solo hub" >>"$(home a)/.config/srcsync/config"
for d in src/app src/app-wt src/lib src/solo; do
	stamp a $d index 202001010000
	stamp a $d logs/HEAD 202001010000
done
echo "a app-wt, recent" >>"$(home a)/src/app-wt/README"
touch "$(g a src/app-wt rev-parse --path-format=absolute --git-path index)"
touch "$(g a src/solo-wt rev-parse --path-format=absolute --git-path index)"
SRCSYNC_STOP_AFTER_CHECKPOINT=1 on a publish
hub_now=$(git -C "$GH/hub.git" show main:machines/a.json)
assert_eq "a app-wt, recent" "$(git -C "$(home a)/src/app" show \
	"$(jq -r '.repos["src/app"].worktrees["src/app-wt"].snapshot' <<<"$hub_now"):README" | tail -1)" \
	"the checkpoint happened"
assert_eq null "$(jq -c '.repos["src/solo"]' <<<"$hub_now")" "without the new repo"
on a publish
assert_eq '["src/solo","src/solo-wt"]' "$(git -C "$GH/hub.git" show main:machines/a.json |
	jq -c '.repos["src/solo"].worktrees | keys')" "which the end of the run adds whole"

done_testing
