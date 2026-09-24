#!/usr/bin/env bash
# .sleep, .wakeup and open.sh are thin wrappers sleepwatcher and the
# sessionizer call directly, each running SRCSYNC_BIN with one fixed
# argument list. These tests check the wrapping: the fake SRCSYNC_BIN
# records what reached it, and open.sh's cap is checked against a fake and a
# real apply that both outlive it.
#
#   ./triggers.test.sh

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PKG=$(cd "$TESTS/../../.." && pwd -P) # the srcsync stow package
SLEEP="$PKG/.sleep"
WAKEUP="$PKG/.wakeup"
OPEN="$TESTS/../open.sh"

RECORD="$WORK/record"
FAKE="$WORK/fake-bin"
cat >"$FAKE" <<'EOF'
#!/bin/bash
echo "$*" >>"$RECORD_FILE"
EOF
chmod +x "$FAKE"

export RECORD_FILE="$RECORD"

printf '.sleep and .wakeup\n'

rm -f "$RECORD"
HOME="$WORK/nobody" SRCSYNC_BIN="$FAKE" "$SLEEP"
assert_eq "auto sleep" "$(cat "$RECORD" 2>/dev/null)" ".sleep records auto sleep"

rm -f "$RECORD"
HOME="$WORK/nobody" SRCSYNC_BIN="$FAKE" "$WAKEUP"
assert_eq "auto wake" "$(cat "$RECORD" 2>/dev/null)" ".wakeup records auto wake"

rm -f "$RECORD"
HOME="$WORK/nobody" SRCSYNC_BIN="$WORK/nothing-here" "$SLEEP"
rc=$?
assert_eq 0 "$rc" ".sleep exits 0 when SRCSYNC_BIN is missing"

printf 'open.sh\n'

rm -f "$RECORD"
SRCSYNC_BIN="$FAKE" "$OPEN" /some/dir
assert_eq "auto open /some/dir" "$(cat "$RECORD" 2>/dev/null)" "open.sh records auto open <dir>"

# A fake that runs past the cap: it also forks its own child, the way auto's
# git subprocesses do. Killed at the cap, a run could stop between a checkout
# and the lay that follows it, so open.sh stops waiting and lets it finish.
SLOW_FAKE="$WORK/slow-fake"
cat >"$SLOW_FAKE" <<'EOF'
#!/bin/bash
echo "$*" >>"$RECORD_FILE"
sleep 3 &
wait
echo finished >>"$RECORD_FILE"
EOF
chmod +x "$SLOW_FAKE"

rm -f "$RECORD"
start=$(date +%s)
SRCSYNC_BIN="$SLOW_FAKE" SRCSYNC_OPEN_TIMEOUT=1 "$OPEN" /some/dir
rc=$?
elapsed=$(($(date +%s) - start))
assert_eq 0 "$rc" "open.sh still exits 0 at the cap"
assert_eq yes "$([ "$elapsed" -le 2 ] && echo yes || echo no)" "and returns within 2 seconds"
assert_eq yes "$(pgrep -f "$SLOW_FAKE" >/dev/null 2>&1 && echo yes || echo no)" \
	"leaving the run going"

# Waits up to 10 seconds for the condition in $1 to hold.
await() { # shell-condition
	local n=0
	until eval "$1" || [ "$n" -ge 100 ]; do
		sleep 0.1
		n=$((n + 1))
	done
}
await 'grep -qx finished "$RECORD" 2>/dev/null'
assert_eq "auto open /some/dir
finished" "$(cat "$RECORD" 2>/dev/null)" "which finishes on its own"

printf 'an apply that outlasts the cap\n'

# A real apply, with git clean slowed so the cap lands between the checkout
# and the lay. It used to be killed there, leaving the worktree at a's head
# without a's edit or new file.
REALGIT=$(command -v git)
mkdir -p "$WORK/bin"
cat >"$WORK/bin/git" <<G
#!/bin/bash
[ "\$1" = clean ] && sleep 3
exec $REALGIT "\$@"
G
chmod +x "$WORK/bin/git"
machine a
machine b
echo "auto on" >"$(home a)/.config/srcsync/config"
echo "auto on" >"$(home b)/.config/srcsync/config"
github_repo app a src/app
git clone -q "$GHURL/app.git" "$(home b)/src/app" 2>/dev/null
on a publish
on b publish
on b apply
on a apply
echo two >>"$(home a)/src/app/README"
g a src/app commit -q -a -m second
echo wip >>"$(home a)/src/app/README"
echo new >"$(home a)/src/app/new.txt"
on a publish
start=$(date +%s)
HOME=$WORK/b SRCSYNC_HOST=b SRCSYNC_HUB=$GH/hub.git PATH="$WORK/bin:$PATH" SRCSYNC_OPEN_TIMEOUT=1 \
	SRCSYNC_BIN=$SRCSYNC "$OPEN" "$(home b)/src/app"
elapsed=$(($(date +%s) - start))
assert_eq yes "$([ "$elapsed" -le 2 ] && echo yes || echo no)" "open.sh returns at the cap"
await 'grep -q "src/app: took a" "$(home b)/.local/state/srcsync/auto.log" 2>/dev/null &&
	[ ! -d "$(home b)/.local/state/srcsync/lock" ]'
assert_eq "$(g a src/app rev-parse HEAD)" "$(g b src/app rev-parse HEAD)" "b ends at a's head"
assert_eq "$(changes a src/app)" "$(changes b src/app)" "with a's edit and new file"
assert_eq "$(g a src/app rev-parse HEAD)" \
	"$(jq -r '.repos["src/app"].worktrees["src/app"].head' "$(home b)/.local/state/srcsync/last.json")" \
	"and records it"
on b apply
assert_eq "" "$(jq -r '.[].worktree' "$(home b)/.local/state/srcsync/conflicts.json")" \
	"so the next apply finds no conflict"

done_testing
