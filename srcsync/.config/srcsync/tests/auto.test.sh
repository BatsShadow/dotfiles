#!/usr/bin/env bash
# Every trigger (Claude hooks, the launchd timer, sleep/wake, the tmux
# sessionizer) calls `auto <event> [path]`. Off, the default, it only logs
# what it would run: that is what keeps live hooks harmless before `auto on`
# is in the config. On, it runs the same publish/apply the plain commands do,
# under the same lock, and sleep waits out a held lock because it is the last
# chance before the lid closes.
#
#   ./auto.test.sh

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

machine a
machine b
github_repo app a src/app

auto_log() { cat "$(home a)/.local/state/srcsync/auto.log" 2>/dev/null; }

printf 'off by default\n'

echo "a's app change" >>"$(home a)/src/app/README"
on a auto stop "$(home a)/src/app"
rc=$?
assert_eq 0 "$rc" "auto stop exits 0 while off"
assert_eq 1 "$(auto_log | grep -cE 'dry stop .*/src/app would run publish')" \
	"and logs what it would have run"
assert_eq "no" "$([ -e "$(home a)/.local/state/srcsync/last.json" ] && echo yes || echo no)" \
	"without creating last.json"
assert_eq "" "$(refs_in hub)" "or touching the hub"
assert_eq "no" "$(git -C "$GH/hub.git" rev-parse -q --verify refs/heads/main >/dev/null 2>&1 && echo yes || echo no)" \
	"which has no main branch"

printf 'on: runs the command, under the lock\n'

printf 'auto on\n' >"$(home a)/.config/srcsync/config"
on a auto stop "$(home a)/src/app"
rc=$?
assert_eq 0 "$rc" "auto stop exits 0 while on"
assert_eq "yes" "$(git -C "$GH/hub.git" show main:machines/a.json >/dev/null 2>&1 && echo yes || echo no)" \
	"a's hub file exists"
assert_eq "refs/srcsync/a/src/app/tree" "$(refs_in hub | cut -d' ' -f2)" \
	"and a snapshot ref for src/app exists"

printf 'timer runs a full sync\n'

git clone -q "$GHURL/app.git" "$(home b)/src/app" 2>/dev/null
printf 'auto on\n' >"$(home b)/.config/srcsync/config"
on b auto timer
assert_eq "a's app change" "$(tail -1 "$(home b)/src/app/README")" \
	"b's timer picks up a's change"

printf 'an unknown event\n'

on a auto bogus
assert_eq 2 "$?" "auto bogus exits 2"

printf 'a hub it cannot reach\n'

# A fresh machine: one that already cloned the hub would still reach it over
# its remembered origin, override or not.
machine c
printf 'auto on\n' >"$(home c)/.config/srcsync/config"
HOME=$(home c) SRCSYNC_HOST=c SRCSYNC_HUB="$WORK/no-such-hub" \
	/bin/bash "$SRCSYNC" auto wake 2>>"$WORK/c.log"
rc=$?
assert_eq 0 "$rc" "auto wake still exits 0 when the hub is unreachable"
assert_eq 1 "$(grep -c 'cannot reach the hub' "$(home c)/.local/state/srcsync/auto.log")" \
	"and auto.log says why"

printf 'the log is trimmed to 2000 lines\n'

seq 1 2500 >"$(home a)/.local/state/srcsync/auto.log"
on a auto stop "$(home a)/src/app"
assert_eq 2000 "$(auto_log | wc -l | tr -d ' ')" "auto.log keeps only its last 2000 lines"

printf 'sleep waits for a held lock, then publishes\n'

machine s
github_repo appS s src/app
printf 'auto on\n' >"$(home s)/.config/srcsync/config"
state_s=$(home s)/.local/state/srcsync
mkdir -p "$state_s"
sleep 30 &
holder=$!
mkdir "$state_s/lock"
echo "$holder" >"$state_s/lock/pid"
on s auto sleep &
job=$!
sleep 2
kill "$holder" 2>/dev/null
wait "$job"
rc=$?
assert_eq 0 "$rc" "auto sleep exits 0 once the lock frees"
assert_eq "yes" "$(git -C "$GH/hub.git" show main:machines/s.json >/dev/null 2>&1 && echo yes || echo no)" \
	"and the publish it waited for happened"

printf 'sleep gives up if the lock never frees\n'

machine s2
printf 'auto on\n' >"$(home s2)/.config/srcsync/config"
state_s2=$(home s2)/.local/state/srcsync
mkdir -p "$state_s2/lock"
sleep 60 &
holder2=$!
echo "$holder2" >"$state_s2/lock/pid"
start=$(date +%s)
on s2 auto sleep
rc=$?
elapsed=$(($(date +%s) - start))
kill "$holder2" 2>/dev/null
assert_eq 0 "$rc" "auto sleep still exits 0 when the lock never frees"
assert_eq yes "$([ "$elapsed" -le 25 ] && echo yes || echo no)" "and returns within 25 seconds"

printf 'concurrent off-mode runs do not clobber the log\n'

# Off mode takes no lock, so every trigger racing auto at once, exactly the
# scenario the design expects, is the case that has to be safe unsynchronized.
machine con
github_repo appcon con src/app
i=0
while [ $i -lt 20 ]; do
	on con auto stop "$(home con)/src/app" &
	i=$((i + 1))
done
wait
log=$(home con)/.local/state/srcsync/auto.log
assert_eq yes "$([ -s "$log" ] && echo yes || echo no)" \
	"auto.log survives 20 concurrent runs non-empty"
total=$(wc -l <"$log" | tr -d ' ')
well_formed=$(grep -cE '^[0-9]{4}(-[0-9]{2}){2}T[0-9]{2}(:[0-9]{2}){2}Z dry stop .*/src/app would run publish .*/src/app$' "$log")
assert_eq "$total" "$well_formed" "every line in it is a complete, well-formed entry"

done_testing
