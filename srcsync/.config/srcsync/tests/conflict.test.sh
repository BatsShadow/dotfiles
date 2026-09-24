#!/usr/bin/env bash
# When not to apply. Both machines changed the worktree: nothing moves on
# either side, and the conflict is recorded for the status bar and the picker.
# A Claude working in the worktree: wait for the next run. An idle Claude, which
# is how Claude nearly always is, does not block anything.
#
#   ./conflict.test.sh

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

machine a
machine b
github_repo app a src/app
on a publish
on b apply
on b publish

printf 'both sides changed\n'

echo "a's version" >"$(home a)/src/app/README"
echo "b's version" >"$(home b)/src/app/README"
on a publish
on b publish
on a apply
on b apply
assert_eq "a's version" "$(cat "$(home a)/src/app/README")" "a keeps its own change"
assert_eq "b's version" "$(cat "$(home b)/src/app/README")" "b keeps its own change"
assert_eq "src/app a" \
	"$(jq -r '.[] | "\(.worktree) \(.host)"' "$(home b)/.local/state/srcsync/conflicts.json")" \
	"b records the conflict with a"
assert_eq "conflict: src/app (a)" "$(on b status | grep conflict)" "and status reports it"
assert_eq "b's version" "$(git -C "$GH/hub.git" show "refs/srcsync/b/src/app/tree:README" 2>/dev/null)" \
	"b's side is kept in the hub as a snapshot"

printf 'a Claude at work\n'

github_repo svc a src/svc
on a publish
on b apply
on b publish
echo "a's change" >>"$(home a)/src/svc/README"
on a publish
sleep 30 &
session b busy src/svc $!
on b apply
assert_eq "hello" "$(cat "$(home b)/src/svc/README")" "a busy Claude holds the apply off"
assert_eq 1 "$(grep -c 'Claude is working there' "$WORK/b.log")" "and says why"

session b busy src/svc/sub $!
rm "$(home b)/.claude/sessions/$!.json"
session b idle src/svc $!
on b apply
assert_eq "hello
a's change" "$(cat "$(home b)/src/svc/README")" "an idle Claude does not"
kill $! 2>/dev/null

printf 'a session file left by a crash\n'

on b publish
echo "again" >>"$(home a)/src/svc/README"
on a publish
session b busy src/svc 99999
on b apply
assert_eq "again" "$(tail -1 "$(home b)/src/svc/README")" "a dead pid's busy file blocks nothing"

done_testing
