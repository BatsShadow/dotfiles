#!/usr/bin/env bash
# Claude's Stop and SessionEnd hooks publish only the worktree the turn ran
# in, and one that finds the lock held queues that worktree for the holder
# instead of leaving it to the next timer run.
#
#   ./wanted.test.sh

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

machine a
echo "auto on" >"$(home a)/.config/srcsync/config"
github_repo app a src/app
github_repo lib a src/lib
g a src/app worktree add -q -b spike "$(home a)/src/app-wt"
g a src/app worktree add -q -b old "$(home a)/src/app-old"
on a publish
state=$(home a)/.local/state/srcsync
last=$state/last.json

# The entry a's last.json holds for worktree $2 of repo $1.
entry() { jq -c --arg r "$1" --arg w "$2" '.repos[$r].worktrees[$w]' "$last"; }

printf 'the stop hook publishes one worktree\n'

echo "main wip" >>"$(home a)/src/app/README"
echo "wt wip" >>"$(home a)/src/app-wt/README"
g a src/app worktree remove --force "$(home a)/src/app-old"
mkdir -p "$(home a)/src/app-wt/sub"
app_before=$(entry src/app src/app)
old_before=$(entry src/app src/app-old)
wt_before=$(entry src/app src/app-wt)
on a auto stop "$(home a)/src/app-wt/sub"
assert_eq yes "$([ "$(entry src/app src/app-wt)" != "$wt_before" ] && echo yes || echo no)" \
	"the worktree the turn ran in is published"
assert_eq "wt wip" "$(g a src/app show "$(jq -r .snapshot <<<"$(entry src/app src/app-wt)"):README" | tail -1)" \
	"with its change"
assert_eq "$app_before" "$(entry src/app src/app)" "its repo's other worktree is left as it was"
assert_eq "$old_before" "$(entry src/app src/app-old)" "and so is one removed since"
assert_eq "{}" "$(jq -c '.repos["src/app"].removed' "$last")" "which is not marked removed"
assert_eq "$(jq -c .repos "$last")" "$(git -C "$GH/hub.git" show main:machines/a.json | jq -c .repos)" \
	"and the hub file matches"

printf 'a plain publish of a path still covers its repo\n'

on a publish "$(home a)/src/app"
assert_eq "main wip" "$(g a src/app show "$(jq -r .snapshot <<<"$(entry src/app src/app)"):README" | tail -1)" \
	"the main worktree is published"
assert_eq '["src/app-old"]' "$(jq -c '.repos["src/app"].removed | keys' "$last")" "and the removal"

printf 'a held lock queues the worktree\n'

sleep 60 &
holder=$!
mkdir "$state/lock"
echo "$holder" >"$state/lock/pid"
on a auto stop "$(home a)/src/lib"
on a auto end "$(home a)/src/lib"
on a auto stop "$(home a)/nowhere"
kill "$holder" 2>/dev/null
rm -rf "$state/lock"
assert_eq "$(home a)/src/lib" "$(cat "$state/wanted" 2>/dev/null)" "the worktree is queued once"

printf 'the holder publishes what was queued during its run\n'

# A git that, in the middle of a's publish of app, has lib's Claude turn end
# and its Stop hook find the lock held.
REALGIT=$(command -v git)
mkdir -p "$WORK/bin"
cat >"$WORK/bin/git" <<G
#!/bin/bash
if [ "\$3" = commit-tree ] && [ ! -e "$WORK/fired" ]; then
	touch "$WORK/fired"
	echo "lib wip" >>"$(home a)/src/lib/README"
	/bin/bash "$SRCSYNC" auto stop "$(home a)/src/lib"
	cp "$state/wanted" "$WORK/wanted-then"
fi
exec $REALGIT "\$@"
G
chmod +x "$WORK/bin/git"
rm -f "$state/wanted"
echo "more main wip" >>"$(home a)/src/app/README"
PATH="$WORK/bin:$PATH" on a publish "$(home a)/src/app"
assert_eq "$(home a)/src/lib" "$(cat "$WORK/wanted-then" 2>/dev/null)" "lib was queued mid-run"
assert_eq "lib wip" "$(g a src/lib show "$(jq -r .snapshot <<<"$(entry src/lib src/lib)"):README" | tail -1)" \
	"and published by the same run"
assert_eq "$(jq -c .repos "$last")" "$(git -C "$GH/hub.git" show main:machines/a.json | jq -c .repos)" \
	"the hub file has it"
assert_eq no "$([ -s "$state/wanted" ] && echo yes || echo no)" "and the queue is empty"

printf 'a queued path that is gone is dropped\n'

g a src/app worktree add -q -b brief "$(home a)/src/app-brief"
printf '%s\n' "$(home a)/src/app-brief" >"$state/wanted"
g a src/app worktree remove --force "$(home a)/src/app-brief"
: >"$WORK/a.log"
on a publish
assert_eq 1 "$(grep -c "src/app-brief: no longer a synced worktree" "$WORK/a.log")" "with one log line"
assert_eq no "$([ -s "$state/wanted" ] && echo yes || echo no)" "and leaves the queue empty"

done_testing
