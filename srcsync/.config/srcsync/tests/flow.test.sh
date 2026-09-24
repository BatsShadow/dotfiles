#!/usr/bin/env bash
# Two machines with `auto on`, driven only through the triggers the real ones
# will fire: the Stop hook, .sleep and .wakeup, open.sh, and the launchd
# command line. Nothing here calls publish or apply by name except resolve,
# which is what the picker runs. The Stop hook returns before its run is done,
# so the steps after it poll the hub, with a bound, instead of sleeping.
#
#   ./flow.test.sh

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PKG=$(cd "$TESTS/../../.." && pwd -P) # the srcsync stow package
ROOT=$(cd "$PKG/.." && pwd -P)
HOOK=$ROOT/claude/.claude/hooks/srcsync-hook.sh
SEGMENT=$ROOT/tmux/.config/tmux-powerline/segments/srcsync.sh

# Runs a trigger as machine $1, with what `on` sets exported and SRCSYNC_BIN
# pointing at the real srcsync.sh.
as() { # machine command
	local m=$1
	shift
	own "$m"
	HOME=$WORK/$m SRCSYNC_HOST=$m SRCSYNC_HUB=$GH/hub.git SRCSYNC_BIN=$SRCSYNC "$@"
}

# Feeds the Stop hook a payload for ~/$2 on machine $1.
stop_hook() { # machine dir
	jq -n --arg c "$WORK/$1/$2" '{hook_event_name: "Stop", session_id: "s", cwd: $c}' |
		as "$1" "$HOOK"
}

# Polls a command every 0.2 seconds for up to $1 seconds.
within() { # seconds command
	local n=$(($1 * 5))
	shift
	while ! "$@"; do
		n=$((n - 1))
		[ "$n" -gt 0 ] || return 1
		sleep 0.2
	done
}

# True once machine $1's hub file holds ~/$2's current tree, and its run has
# let go of the lock.
published() { # machine dir
	local want got
	want=$(lib "$1" worktree_tree "$WORK/$1/$2")
	got=$(git -C "$GH/hub.git" show "main:machines/$1.json" 2>/dev/null |
		jq -r --arg w "$2" '.repos[$w].worktrees[$w].tree // ""')
	[ "$want" = "$got" ] && [ ! -d "$WORK/$1/.local/state/srcsync/lock" ]
}

state() { echo "$WORK/$1/.local/state/srcsync"; }

machine a
machine b
printf 'auto on\nsync src/notes hub\n' >"$(home a)/.config/srcsync/config"
echo "auto on" >"$(home b)/.config/srcsync/config"
github_repo app a src/app
git clone -q "$GHURL/app.git" "$(home b)/src/app" 2>/dev/null
git init -q "$(home a)/src/notes"
echo "private" >"$(home a)/src/notes/todo"
g a src/notes add todo
g a src/notes commit -q -m "notes"

printf 'a Claude turn on a, then the lid closes\n'

echo "a's edit" >>"$(home a)/src/app/README"
start=$(date +%s)
stop_hook a src/app
assert_eq yes "$([ $(($(date +%s) - start)) -le 1 ] && echo yes || echo no)" \
	"the Stop hook returns within a second"
within 10 published a src/app
assert_eq 0 "$?" "a's hub file shows the edit"
as a "$PKG/.sleep"
assert_eq yes "$(git -C "$GH/hub.git" show main:machines/a.json | jq -r 'if .repos["src/notes"] then "yes" else "no" end')" \
	".sleep publishes the repo the Stop hook left out"

printf 'b wakes\n'

as b "$PKG/.wakeup"
assert_eq "hello
a's edit" "$(cat "$(home b)/src/app/README")" "b has a's edit"
assert_eq "private" "$(cat "$(home b)/src/notes/todo" 2>/dev/null)" "and the repo with no remote"

printf 'b opens the worktree and works in it\n'

echo "b's file" >"$(home b)/src/app/from-b"
as b "$ROOT/srcsync/.config/srcsync/open.sh" "$(home b)/src/app"
assert_eq "b's file" "$(cat "$(home b)/src/app/from-b")" "open.sh takes nothing and keeps b's work"
stop_hook b src/app
within 10 published b src/app
assert_eq 0 "$?" "b's hub file shows the new file"
as a /bin/bash "$SRCSYNC" auto timer
assert_eq "b's file" "$(cat "$(home a)/src/app/from-b" 2>/dev/null)" "a's timer brings it over"

printf 'both edit the same worktree\n'

echo "a again" >"$(home a)/src/app/README"
echo "b again" >"$(home b)/src/app/README"
stop_hook a src/app
stop_hook b src/app
within 10 published a src/app
assert_eq 0 "$?" "a publishes its side"
within 10 published b src/app
assert_eq 0 "$?" "b publishes its side"
as a /bin/bash "$SRCSYNC" auto timer
assert_eq "a again" "$(cat "$(home a)/src/app/README")" "a's timer keeps a's side"
assert_eq "src/app" "$(on a conflicts | cut -f1)" "and lists the conflict"
assert_eq "⇄ !1" "$(SRCSYNC_STATE=$(state a) SRCSYNC_CONFIG=$(home a)/.config/srcsync/config \
	bash -c '. "$1"; run_segment' _ "$SEGMENT")" "the status segment shows it"
on a resolve "$(home a)/src/app" mine
as b /bin/bash "$SRCSYNC" auto timer
assert_eq "a again" "$(cat "$(home b)/src/app/README")" "keeping mine on a: b's timer takes a's side"
assert_eq "[]" "$(jq -c . "$(state a)/conflicts.json")" "a has no conflicts"
assert_eq "[]" "$(jq -c . "$(state b)/conflicts.json")" "b has no conflicts"

printf 'auto off on b\n'

echo "auto off" >"$(home b)/.config/srcsync/config"
echo "a's last edit" >"$(home a)/src/app/README"
stop_hook a src/app
within 10 published a src/app
assert_eq 0 "$?" "a publishes"
before=$(cat "$(state b)/last.json")
as b "$PKG/.wakeup"
assert_eq "a again" "$(cat "$(home b)/src/app/README")" ".wakeup changes nothing on b"
assert_eq "$before" "$(cat "$(state b)/last.json")" "or in b's last.json"
case $(tail -1 "$(state b)/auto.log") in
*" dry wake - would run apply") pass "auto.log gains a dry wake line" ;;
*) fail "auto.log gains a dry wake line" "got: $(tail -1 "$(state b)/auto.log")" ;;
esac

done_testing
