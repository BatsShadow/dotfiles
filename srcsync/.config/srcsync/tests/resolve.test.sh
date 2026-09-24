#!/usr/bin/env bash
# Settling a conflict. Taking theirs goes through the same checks as an apply
# and keeps the worktree in the before-apply ref first. Keeping mine tells the
# other machine to take this side, and its own side stays in the hub.
#
#   ./resolve.test.sh

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Two machines in sync on src/app, then each changes a different file and b
# applies, which records the conflict on b.
conflicted() { # a b
	machine "$1"
	machine "$2"
	github_repo app "$1" src/app
	on "$1" publish
	on "$2" apply
	on "$2" publish
	on "$1" apply
	echo "$1's change" >"$(home "$1")/src/app/theirs-file"
	echo "$2's change" >"$(home "$2")/src/app/mine-file"
	on "$1" publish
	on "$2" publish
	on "$2" apply
}

# A repo on machine $1 whose snapshots go to an origin that does not exist,
# queued for a push that will fail.
stuck() { # machine
	github_repo other "$1" src/other
	g "$1" src/other remote set-url origin "$GH/missing.git"
	echo "sync src/other origin" >>"$(home "$1")/.config/srcsync/config"
	echo "src/other" >>"$(home "$1")/.local/state/srcsync/pending"
}

printf 'listing conflicts\n'

conflicted a b
line=$(on b conflicts)
assert_eq 1 "$(printf '%s\n' "$line" | grep -c .)" "b lists one conflict"
case $line in
$'src/app\ta\tb main@'*$'\ta main@'*) pass "for src/app with a, each side named by its host" ;;
*) fail "for src/app with a, each side named by its host" "got: $(printf '%q' "$line")" ;;
esac
# Both sides sit on one head, as when only uncommitted work differs. A
# half-applied worktree once looked the same as theirs in the picker.
assert_eq "$(g a src/app rev-parse HEAD)" "$(g b src/app rev-parse HEAD)" "both sides are on one head"
assert_eq yes "$([ "$(cut -f3 <<<"$line" | cut -d' ' -f2-)" != "$(cut -f4 <<<"$line" | cut -d' ' -f2-)" ] &&
	echo yes || echo no)" "and still read differently"

printf 'taking theirs\n'

before=$(lib b worktree_tree "$(home b)/src/app")
stuck b
on b resolve "$(home b)/src/app" theirs
assert_eq 0 "$?" "resolve exits 0, though another repo cannot push"
assert_eq 1 "$(grep -c 'src/other is still unpushed' "$WORK/b.log")" "and b says which"
assert_eq "$(changes a src/app)" "$(changes b src/app)" "b's worktree now matches a's"
assert_eq "" "$(on b conflicts)" "the conflict is gone"
assert_eq "$before" "$(g b src/app rev-parse -q --verify 'refs/srcsync-local/src/app/before-apply^{tree}')" \
	"b's worktree is kept in the before-apply ref"
on b apply
assert_eq "[]" "$(jq -c . "$(home b)/.local/state/srcsync/conflicts.json")" "a later apply finds no conflict"

printf 'keeping mine\n'

rm -rf "$GH"/*.git "$WORK/c" "$WORK/d"
git init -q --bare "$GH/hub.git"
conflicted c d
stuck d
on d resolve "$(home d)/src/app" mine
assert_eq 0 "$?" "resolve exits 0, though another repo cannot push"
assert_eq 1 "$(grep -c 'src/other is still unpushed' "$WORK/d.log")" "and d says which"
assert_eq "" "$(on d conflicts)" "the conflict is gone"
on c apply
assert_eq "d's change" "$(cat "$(home c)/src/app/mine-file" 2>/dev/null)" "c takes d's change"
assert_eq "no" "$([ -e "$(home c)/src/app/theirs-file" ] && echo yes || echo no)" \
	"and loses its own edit from the worktree"
assert_eq "c's change" "$(git -C "$GH/hub.git" show refs/srcsync/c/src/app/tree:theirs-file 2>/dev/null)" \
	"which its snapshot still holds in the hub"
assert_eq "[]" "$(jq -c . "$(home c)/.local/state/srcsync/conflicts.json")" "c records no conflict"

printf 'no conflict\n'

out=$(on d resolve "$(home d)/src/app" theirs 2>&1)
assert_eq 1 "$?" "resolve exits 1"
assert_eq 1 "$(grep -c 'src/app: no conflict' "$WORK/d.log")" "and says so"

printf 'a Claude at work\n'

rm -rf "$GH"/*.git "$WORK/e" "$WORK/f"
git init -q --bare "$GH/hub.git"
conflicted e f
session f busy src/app $$
on f resolve "$(home f)/src/app" theirs
assert_eq 1 "$?" "resolve exits 1"
assert_eq 1 "$(grep -c 'Claude is working there' "$WORK/f.log")" "and says why"
assert_eq "f's change" "$(cat "$(home f)/src/app/mine-file" 2>/dev/null)" "f's change is untouched"
assert_eq 1 "$(on f conflicts | grep -c .)" "the conflict stays"

printf 'a local branch the other side lacks commits of\n'

rm -rf "$GH"/*.git "$WORK/g" "$WORK/h"
git init -q --bare "$GH/hub.git"
conflicted g h
g h src/app commit -q --allow-empty -m "h's commit"
g h src/app checkout -q -b side
on h resolve "$(home h)/src/app" theirs
assert_eq 1 "$?" "resolve exits 1"
assert_eq 1 "$(grep -c 'branch main has commits here that g lacks' "$WORK/h.log")" "and says why"
assert_eq "side" "$(g h src/app branch --show-current)" "h's worktree stays where it was"

printf 'the picker\n'

# fzf and the key press stand in for a person: fzf picks the first row with
# enter, and the key waits on a fifo until the test writes to it.
rm -rf "$GH"/*.git "$WORK/i" "$WORK/j"
git init -q --bare "$GH/hub.git"
conflicted i j
mkdir -p "$WORK/bin"
printf '#!/bin/sh\necho\nhead -1\n' >"$WORK/bin/fzf"
chmod +x "$WORK/bin/fzf"
mkfifo "$WORK/key"
PATH=$WORK/bin:$PATH on j pick <"$WORK/key" >"$WORK/pick.out" &
picker=$!
exec 3>"$WORK/key"
n=0
until grep -q 'press a key' "$WORK/pick.out" || [ $n -ge 300 ]; do
	sleep 0.1
	n=$((n + 1))
done
assert_eq "" "$(on j conflicts)" "enter takes theirs"
on j publish
assert_eq 0 "$(grep -c 'another run holds the lock' "$WORK/j.log")" \
	"a publish runs while the picker waits for a key"
echo >&3
exec 3>&-
wait $picker
assert_eq 0 "$?" "and the picker exits on the key"

done_testing
