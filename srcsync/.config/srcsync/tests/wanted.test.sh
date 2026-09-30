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

# The paths queued for the lock holder, one per line.
queued() { cat "$state"/wanted.d/* 2>/dev/null; }

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
assert_eq "$(home a)/src/lib" "$(queued)" "the worktree is queued once"

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
	cat "$state"/wanted.d/* >"$WORK/wanted-then" 2>/dev/null
fi
exec $REALGIT "\$@"
G
chmod +x "$WORK/bin/git"
rm -rf "$state/wanted.d"
echo "more main wip" >>"$(home a)/src/app/README"
PATH="$WORK/bin:$PATH" on a publish "$(home a)/src/app"
assert_eq "$(home a)/src/lib" "$(cat "$WORK/wanted-then" 2>/dev/null)" "lib was queued mid-run"
assert_eq "lib wip" "$(g a src/lib show "$(jq -r .snapshot <<<"$(entry src/lib src/lib)"):README" | tail -1)" \
	"and published by the same run"
assert_eq "$(jq -c .repos "$last")" "$(git -C "$GH/hub.git" show main:machines/a.json | jq -c .repos)" \
	"the hub file has it"
assert_eq "" "$(queued)" "and the queue is empty"

printf 'a queued path that is gone is dropped\n'

g a src/app worktree add -q -b brief "$(home a)/src/app-brief"
mkdir -p "$state/wanted.d"
printf '%s\n' "$(home a)/src/app-brief" >"$state/wanted.d/1"
g a src/app worktree remove --force "$(home a)/src/app-brief"
: >"$WORK/a.log"
on a publish
assert_eq 1 "$(grep -c "src/app-brief: no longer a synced worktree" "$WORK/a.log")" "with one log line"
assert_eq "" "$(queued)" "and leaves the queue empty"

printf 'an apply that holds the lock publishes the queue too\n'

# A turn that ends during a wake apply is published by that run, not left
# for the next timer run.
echo "lib during wake" >>"$(home a)/src/lib/README"
cat >"$WORK/bin/git" <<G
#!/bin/bash
if [ "\$1" = -C ] && [ "\$3" = ls-remote ] && [ ! -e "$WORK/fired-wake" ]; then
	touch "$WORK/fired-wake"
	/bin/bash "$SRCSYNC" auto stop "$(home a)/src/lib"
fi
exec $REALGIT "\$@"
G
PATH="$WORK/bin:$PATH" on a auto wake
assert_eq yes "$([ -e "$WORK/fired-wake" ] && echo yes || echo no)" "a turn ended during the apply"
assert_eq "lib during wake" "$(g a src/lib show "$(jq -r .snapshot <<<"$(entry src/lib src/lib)"):README" | tail -1)" \
	"and the apply's run published it"
assert_eq "" "$(queued)" "leaving the queue empty"

printf 'a queued worktree the walk already covered is not snapshotted twice\n'

# The turn in app ends while the full run is snapshotting app itself, so the
# queue names a worktree whose state this run has just taken.
machine d
github_repo appd d src/app
cat >"$WORK/bin/git" <<G
#!/bin/bash
case "\$1 \$3" in
"-C commit-tree")
	echo commit-tree >>"$WORK/d-git.log"
	if [ ! -e "$WORK/fired-d" ]; then
		touch "$WORK/fired-d"
		HOME=$(home d) SRCSYNC_HOST=d SRCSYNC_HUB=$GH/hub.git /bin/bash "$SRCSYNC" auto stop "$(home d)/src/app"
	fi
	;;
"-C push") [ "\$2" = "$(home d)/src/app" ] && echo push >>"$WORK/d-git.log" ;;
esac
exec $REALGIT "\$@"
G
echo "auto on" >>"$(home d)/.config/srcsync/config"
echo "d wip" >>"$(home d)/src/app/README"
PATH="$WORK/bin:$PATH" on d publish
assert_eq yes "$([ -e "$WORK/fired-d" ] && echo yes || echo no)" "app was queued during its own snapshot"
assert_eq "commit-tree push" "$(tr '\n' ' ' <"$WORK/d-git.log" | sed 's/ $//')" \
	"one snapshot and one push, not two"
assert_eq "d wip" "$(g d src/app show "$(jq -r '.repos["src/app"].worktrees["src/app"].snapshot' \
	"$(home d)/.local/state/srcsync/last.json"):README" | tail -1)" "and last.json names it"

printf 'a hook in a linked worktree of a repo new to the hub\n'

# A repo with no remote reaches b only through the hub. Published without its
# main worktree, b would init it empty and never read it again.
machine b
mkdir -p "$(home a)/src/solo"
git -C "$(home a)/src/solo" init -q
echo "solo" >"$(home a)/src/solo/README"
g a src/solo add README
g a src/solo commit -q -m first
g a src/solo worktree add -q -b side "$(home a)/src/solo-wt"
echo "side" >>"$(home a)/src/solo-wt/README"
echo "sync src/solo hub" >>"$(home a)/.config/srcsync/config"
on a auto stop "$(home a)/src/solo-wt"
assert_eq '["src/solo","src/solo-wt"]' "$(jq -c '.repos["src/solo"].worktrees | keys' "$last")" \
	"the whole repo is published"
on b apply
assert_eq "solo" "$(cat "$(home b)/src/solo/README" 2>/dev/null)" "b builds its main worktree"
assert_eq "solo
side" "$(cat "$(home b)/src/solo-wt/README" 2>/dev/null)" "and the linked one"

done_testing
