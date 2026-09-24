#!/usr/bin/env bash
# Claude transcripts published beside the code, with `transcripts on`. Each
# machine's projects dir is the default one under its fake $HOME, so nothing
# here can reach the real ~/.claude/projects.
#
#   ./transcripts.test.sh

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
unset CC_PROJECTS_DIR

state() { echo "$WORK/$1/.local/state/srcsync"; }
# The projects dir Claude would use for ~/$2 on machine $1.
projects() { # machine dir
	echo "$WORK/$1/.claude/projects/$(printf '%s' "$(cd "$WORK/$1/$2" && pwd -P)" | tr -c 'A-Za-z0-9' '-')"
}
entry_of() { # machine key
	jq -c --arg k "$2" '.repos[$k].worktrees[$k]' "$(state "$1")/last.json"
}
hub_ref() { git -C "$GH/hub.git" rev-parse -q --verify "$1"; }

machine a
machine b
echo "transcripts on" >"$(home a)/.config/srcsync/config"
echo "transcripts on" >"$(home b)/.config/srcsync/config"
github_repo app a src/app
git clone -q "$GHURL/app.git" "$(home b)/src/app" 2>/dev/null

printf 'publishing the claude tree\n'
P=$(projects a src/app)
mkdir -p "$P/memory" "$P/other"
echo '{"n":1}' >"$P/s1.jsonl"
echo "remember" >"$P/memory/MEMORY.md"
echo '{"n":0}' >"$P/other/sub.jsonl"
on a publish
C1=$(entry_of a src/app | jq -r .claude)
[ -n "$C1" ] && [ "$C1" != null ] && pass "the worktree entry has a claude tree" ||
	fail "the worktree entry has a claude tree" "got: $C1"
REF=refs/srcsync/a/src/app/claude
assert_eq "$(printf 'memory/MEMORY.md\ns1.jsonl')" \
	"$(git -C "$GH/hub.git" ls-tree -r --name-only "$REF" 2>&1)" \
	"the hub's claude ref holds s1.jsonl and memory, not other/"
assert_eq "$C1" "$(git -C "$GH/hub.git" rev-parse "$REF^{tree}" 2>&1)" \
	"the ref's tree is the one the state file names"
assert_eq "" "$(git -C "$GH/hub.git" rev-list --parents -n1 "$REF" 2>&1 | cut -s -d' ' -f2)" \
	"the claude commit has no parent"
assert_eq "srcsync transcripts of src/app" "$(git -C "$GH/hub.git" log -1 --format=%s "$REF" 2>&1)" \
	"the claude commit names its worktree"
assert_eq "" "$(changes a src/app)" "the worktree is untouched"
[ -f "$(state a)/claude-index/$(basename "$P")" ] && pass "the index lives in the state dir" ||
	fail "the index lives in the state dir"

printf 'nothing changed\n'
MAIN=$(hub_ref main)
REFS=$(refs_in hub)
ENTRY=$(entry_of a src/app)
on a publish
assert_eq "$MAIN" "$(hub_ref main)" "a second publish leaves the hub's main alone"
assert_eq "$REFS" "$(refs_in hub)" "and its refs"
assert_eq "$ENTRY" "$(entry_of a src/app)" "and the entry"

printf 'a transcript grows\n'
sleep 1 # changed_at has one-second resolution
echo '{"n":2}' >>"$P/s1.jsonl"
on a publish
[ "$(hub_ref "$REF")" != "$(grep " $REF\$" <<<"$REFS" | cut -d' ' -f1)" ] &&
	pass "the claude ref moves" || fail "the claude ref moves"
[ "$(entry_of a src/app | jq -r .changed_at)" != "$(jq -r .changed_at <<<"$ENTRY")" ] &&
	pass "changed_at moves" || fail "changed_at moves"
assert_eq "$(jq -c '{branch, head, tracking, tree, snapshot}' <<<"$ENTRY")" \
	"$(entry_of a src/app | jq -c '{branch, head, tracking, tree, snapshot}')" \
	"the code part of the entry stays"
assert_eq "$(printf '{"n":1}\n{"n":2}')" "$(git -C "$GH/hub.git" show "$REF:s1.jsonl" 2>&1)" \
	"the hub has the new line"

printf 'b takes a transcripts\n'
B=$(projects b src/app)
mkdir -p "$B"
echo '{"b":0}' >"$B/s0.jsonl"
on b apply
assert_eq "$(cat "$P/s1.jsonl")" "$(cat "$B/s1.jsonl" 2>&1)" "b has a's s1.jsonl"
assert_eq "remember" "$(cat "$B/memory/MEMORY.md" 2>&1)" "and its memory"
[ -e "$B/other" ] && fail "and not other/" || pass "and not other/"
assert_eq '{"b":0}' "$(cat "$B/s0.jsonl" 2>&1)" "b's own s0.jsonl survives"
assert_eq "" "$(changes b src/app)" "b's worktree is untouched"
BC=$(entry_of b src/app | jq -r .claude)
assert_eq "$BC" "$(git -C "$(home b)/src/app" rev-parse -q --verify "refs/srcsync/b/src/app/claude^{tree}")" \
	"b's claude ref holds the tree its entry names"
assert_eq "$(entry_of a src/app | jq -c '{branch, head, tree, claude}')" \
	"$(entry_of b src/app | jq -c '.base')" "b's base is a's state, transcripts too"
on b publish
on a apply
assert_eq '{"b":0}' "$(cat "$P/s0.jsonl" 2>&1)" "a takes b's s0.jsonl back"
assert_eq "" "$(grep 'left alone' "$WORK/a.log")" "with no conflict"
on a publish
on b apply
assert_eq "[]" "$(jq -c . "$(state b)/conflicts.json")" "and b then has nothing to do"

printf 'only a transcript moved\n'
echo '{"n":3}' >>"$P/s1.jsonl"
on a publish
: >"$WORK/b.log"
session b busy src/app $$
on b apply
rm -f "$(home b)/.claude/sessions/$$.json"
assert_eq "" "$(grep -F '{"n":3}' "$B/s1.jsonl")" "a busy Claude holds the transcripts back too"
touch -t 202001010000 "$B/memory/MEMORY.md"
on b apply
assert_eq "$(cat "$P/s1.jsonl")" "$(cat "$B/s1.jsonl" 2>&1)" "then b's s1.jsonl has the new line"
assert_eq 202001010000 "$(date -r "$B/memory/MEMORY.md" +%Y%m%d%H%M)" \
	"an unchanged file keeps its mtime, so the newest transcript stays newest"
assert_eq 1 "$(grep -c "src/app: took a's state" "$WORK/b.log")" "and b's log says so"

printf 'both append\n'
on b publish
on a apply
echo '{"a":4}' >>"$P/s1.jsonl"
echo '{"b":4}' >>"$B/s1.jsonl"
BS1=$(cat "$B/s1.jsonl")
on a publish
on b publish
on b apply
assert_eq src/app "$(jq -r '.[].worktree' "$(state b)/conflicts.json")" "a conflict on src/app"
assert_eq "$BS1" "$(cat "$B/s1.jsonl")" "b's s1.jsonl keeps b's line"

printf 'resolving theirs\n'
: >"$WORK/b.log"
on b resolve "$(home b)/src/app" theirs
assert_eq "$BS1" "$(cat "$B/s1.jsonl" 2>&1)" "b keeps its s1.jsonl, which a's does not extend"
assert_eq 1 "$(grep -c 'src/app: kept s1.jsonl: both machines added to it' "$WORK/b.log")" "and says so"
assert_eq "$BS1" "$(git -C "$(home b)/src/app" show refs/srcsync-local/src/app/claude-before-apply:s1.jsonl 2>&1)" \
	"b's own line is kept in a local ref"
on b apply
assert_eq "[]" "$(jq -c . "$(state b)/conflicts.json")" "the next apply finds no conflict"
on a apply
assert_eq "" "$(grep 'left alone' "$WORK/a.log")" "nor does a's"

printf 'resolving mine\n'
on a publish
on b apply
echo '{"a":5}' >>"$P/s1.jsonl"
echo '{"b":5}' >>"$B/s1.jsonl"
on a publish
on b publish
on b apply
assert_eq src/app "$(jq -r '.[].worktree' "$(state b)/conflicts.json")" "another conflict"
on b resolve "$(home b)/src/app" mine
on a apply
assert_eq "" "$(grep 'left alone' "$WORK/a.log")" "a takes b's side with no conflict"
grep -qxF '{"a":5}' "$P/s1.jsonl" && pass "a's s1.jsonl keeps a's line" || fail "a's s1.jsonl keeps a's line"
on a publish
on b apply
on a apply
assert_eq "[]" "$(jq -c . "$(state a)/conflicts.json")" "and a settles"

printf 'a file in the way\n'
echo '{"a":6}' >>"$P/s1.jsonl"
echo '{"b":6}' >>"$B/s1.jsonl"
on a publish
on b publish
on b apply
BS1=$(cat "$B/s1.jsonl")
rm -r "$B/memory"
echo "mine" >"$B/memory"
: >"$WORK/b.log"
on b resolve "$(home b)/src/app" theirs
assert_eq 1 "$(grep -c 'src/app: memory in its transcripts is in the way; skipped' "$WORK/b.log")" \
	"taking theirs over a file where theirs has a directory is refused"
assert_eq mine "$(cat "$B/memory")" "the file stays"
assert_eq "$BS1" "$(cat "$B/s1.jsonl")" "and nothing else is laid"

printf 'first contact with a file of its own\n'
machine d
echo "transcripts on" >"$(home d)/.config/srcsync/config"
git clone -q "$GHURL/app.git" "$(home d)/src/app" 2>/dev/null
D=$(projects d src/app)
mkdir -p "$D/memory"
echo "d's" >"$D/memory/MEMORY.md"
on d apply
assert_eq src/app "$(jq -r '.[].worktree' "$(state d)/conflicts.json" | sort -u)" \
	"a MEMORY.md that differs on first contact is a conflict"
assert_eq "d's" "$(cat "$D/memory/MEMORY.md")" "and d keeps its own"
[ -e "$D/s1.jsonl" ] && fail "and nothing is laid" || pass "and nothing is laid"

printf 'a missing worktree over transcripts already here\n'
machine e
echo "transcripts on" >"$(home e)/.config/srcsync/config"
E=$WORK/e/.claude/projects/$(printf '%s' "$WORK/e/src/app" | tr -c 'A-Za-z0-9' '-')
mkdir -p "$E/memory"
echo "e's" >"$E/memory/MEMORY.md"
on e apply
assert_eq src/app "$(jq -r '.[].worktree' "$(state e)/conflicts.json" | sort -u)" \
	"with no worktree either, a MEMORY.md that differs is a conflict"
assert_eq "e's" "$(cat "$E/memory/MEMORY.md")" "and e keeps its own"

printf 'transcripts off here, on there\n'
machine c
echo "transcripts off" >"$(home c)/.config/srcsync/config"
git clone -q "$GHURL/app.git" "$(home c)/src/app" 2>/dev/null
mkdir -p "$(projects c src/app)"
echo '{"n":1}' >"$(projects c src/app)/s1.jsonl"
on c publish
assert_eq false "$(entry_of c src/app | jq 'has("claude")')" "off, the entry has no claude key"
[ -e "$(state c)/claude-index" ] && fail "off, no claude index is made" ||
	pass "off, no claude index is made"
assert_eq "" "$(refs_in hub | grep ' refs/srcsync/c/')" "off, no ref is pushed"
on c apply
on c publish
on c apply
assert_eq "" "$(grep "took a's state" "$WORK/c.log")" "off, a's transcripts alone are nothing to apply"
assert_eq '{"n":1}' "$(cat "$(projects c src/app)/s1.jsonl")" "off, apply lays no transcripts"
[ -e "$(projects c src/app)/memory" ] && fail "not even new ones" || pass "not even new ones"
[ -e "$(state c)/hub-pending" ] && fail "and a second apply leaves hub-pending alone" ||
	pass "and a second apply leaves hub-pending alone"

printf 'a transcript over the size cap\n'
printf 'transcripts on\nmax_size 4K\n' >"$(home a)/.config/srcsync/config"
head -c 16384 /dev/urandom | base64 >>"$P/s1.jsonl"
echo "draft" >"$(home a)/src/app/notes.txt"
: >"$WORK/a.log"
on a publish
assert_eq "" "$(git -C "$GH/hub.git" ls-tree --name-only "$REF" s1.jsonl memory/MEMORY.md | grep s1)" \
	"a transcript over the cap is left out of the pushed tree"
assert_eq "memory" "$(git -C "$GH/hub.git" ls-tree --name-only "$REF" memory)" "and the rest still goes"
assert_eq "$(entry_of a src/app | jq -r .claude)" "$(hub_ref "$REF^{tree}")" \
	"the entry names the tree that was pushed"
assert_eq "$(lib a worktree_tree "$(home a)/src/app")" \
	"$(git -C "$GH/hub.git" rev-parse "refs/srcsync/a/src/app/tree^{tree}" 2>&1)" \
	"the code is published"
assert_eq 1 "$(grep -c 'src/app: transcript s1.jsonl is over the size cap; left out' "$WORK/a.log")" \
	"the log names the file once"
MAIN=$(hub_ref main)
on a publish
assert_eq "$MAIN" "$(hub_ref main)" "still over the cap, a publish changes nothing"
assert_eq "$(entry_of a src/app | jq -r .claude)" "$(lib a claude_tree "$(home a)/src/app" "$(home a)/src/app")" \
	"now reads as the entry"
echo "transcripts on" >"$(home a)/.config/srcsync/config"
on a publish
assert_eq "$(git hash-object "$P/s1.jsonl")" "$(git -C "$GH/hub.git" rev-parse "$REF:s1.jsonl" 2>&1)" \
	"raising the cap publishes it on the next run"

printf 'off writes no transcript objects\n'
# Byte-identity with the pre-transcripts code was checked once, against the
# last commit before this feature; that commit does not survive the squash.
machine n
git clone -q "$GHURL/app.git" "$(home n)/src/app" 2>/dev/null
echo "draft" >"$(home n)/src/app/notes.txt"
mkdir -p "$(projects n src/app)"
echo '{"n":1}' >"$(projects n src/app)/s1.jsonl"
echo "transcripts off" >"$(home n)/.config/srcsync/config"
on n publish
git -C "$(home n)/src/app" cat-file -e "$(git hash-object "$(projects n src/app)/s1.jsonl")" 2>/dev/null &&
	fail "no transcript object is written" || pass "no transcript object is written"

printf 'a union over the cap\n'
machine f
machine g
echo "transcripts on" >"$(home f)/.config/srcsync/config"
printf 'transcripts on\nmax_size 8K\n' >"$(home g)/.config/srcsync/config"
github_repo app2 f src/app2
git clone -q "$GHURL/app2.git" "$(home g)/src/app2" 2>/dev/null
FP=$(projects f src/app2)
GP=$(projects g src/app2)
mkdir -p "$FP" "$GP"
echo '{"f":1}' >"$FP/s1.jsonl"
head -c 16384 /dev/urandom | base64 >"$GP/s0.jsonl"
BIG=$(git hash-object "$GP/s0.jsonl")
on f publish
on g publish
on g apply
assert_eq '{"f":1}' "$(cat "$GP/s1.jsonl" 2>&1)" "g takes f's transcript"
assert_eq "$BIG" "$(git hash-object "$GP/s0.jsonl")" "and keeps its own big one"
on g publish
git -C "$GH/hub.git" cat-file -e "$BIG" 2>/dev/null && fail "the big transcript never reaches the hub" ||
	pass "the big transcript never reaches the hub"
GC=$(jq -r '.repos["src/app2"].worktrees["src/app2"].claude' "$(state g)/last.json")
assert_eq "$GC" "$(git -C "$GH/hub.git" rev-parse -q --verify "refs/srcsync/g/src/app2/claude^{tree}")" \
	"g's entry names the claude tree its pushed ref holds"
on f apply
assert_eq "" "$(grep -E 'src/app2: .*(left alone|cannot fetch)' "$WORK/f.log")" "f neither conflicts nor fails to fetch"
echo "f's code" >"$(home f)/src/app2/code.txt"
echo '{"f":2}' >>"$FP/s1.jsonl"
on f publish
echo more >>"$GP/s0.jsonl"
on g publish
on g apply
assert_eq "f's code" "$(cat "$(home g)/src/app2/code.txt" 2>&1)" "f's next change reaches g"
assert_eq "$(cat "$FP/s1.jsonl")" "$(cat "$GP/s1.jsonl")" "transcripts too"
assert_eq "" "$(grep -E 'src/app2: .*left alone' "$WORK/g.log")" "with no conflict on g"
on g publish
on f apply
assert_eq "" "$(grep -E 'src/app2: .*(left alone|cannot fetch)' "$WORK/f.log")" "nor on f"
git -C "$GH/hub.git" cat-file -e "$(git hash-object "$GP/s0.jsonl")" 2>/dev/null &&
	fail "and still nothing big is pushed" || pass "and still nothing big is pushed"

printf 'both append to a small transcript while a big one is over the cap\n'
echo '{"g":9}' >>"$GP/s1.jsonl"
on g publish
echo '{"f":9}' >>"$FP/s1.jsonl"
on f publish
on g apply
on g publish
on f apply
grep -qxF '{"g":9}' "$GP/s1.jsonl" && pass "g keeps its line" || fail "g keeps its line"
grep -qxF '{"f":9}' "$FP/s1.jsonl" && pass "f keeps its line" || fail "f keeps its line"
assert_eq src/app2 "$(jq -r '.[].worktree' "$(state g)/conflicts.json" | grep app2 | sort -u)" \
	"and g records a conflict"

printf 'raising the cap\n'
echo "transcripts on" >"$(home g)/.config/srcsync/config"
on g publish
assert_eq "$(git hash-object "$GP/s0.jsonl")" \
	"$(git -C "$GH/hub.git" rev-parse refs/srcsync/g/src/app2/claude:s0.jsonl 2>&1)" \
	"the big transcript goes on the next run"
echo more >>"$GP/s0.jsonl"
on g publish
on f apply
grep -qxF '{"f":9}' "$FP/s1.jsonl" && pass "and f still has its line after applying" ||
	fail "and f still has its line after applying"

printf 'a whole tree over the cap\n'
machine h
machine i
printf 'transcripts on\nmax_size 8K\n' >"$(home h)/.config/srcsync/config"
echo "transcripts on" >"$(home i)/.config/srcsync/config"
github_repo app3 h src/app3
git clone -q "$GHURL/app3.git" "$(home i)/src/app3" 2>/dev/null
HP=$(projects h src/app3)
IP=$(projects i src/app3)
mkdir -p "$HP" "$IP"
for n in 1 2 3 4 5; do head -c 3000 /dev/urandom | base64 >"$HP/h$n.jsonl"; done
echo '{"i":1}' >"$IP/s1.jsonl"
app3() { jq -c '.repos["src/app3"].worktrees["src/app3"].claude' "$(state "$1")/last.json"; }
cycle() {
	on h publish
	on i publish
	on i apply
	on h apply
}
cycle
cycle
assert_eq null "$(app3 h)" "h publishes no claude tree"
assert_eq "" "$(lib h claude_tree "$(home h)/src/app3" "$(home h)/src/app3")" "and reads its own as none"
assert_eq '{"i":1}' "$(cat "$HP/s1.jsonl" 2>&1)" "h still takes i's transcript"
TOOK=$(cat "$WORK/h.log" "$WORK/i.log" | grep -c 'src/app3: took')
cycle
cycle
assert_eq "$TOOK" "$(cat "$WORK/h.log" "$WORK/i.log" | grep -c 'src/app3: took')" "and nothing applies again"
assert_eq "" "$(cat "$WORK/h.log" "$WORK/i.log" | grep 'src/app3: .*left alone')" "with no conflict"

printf 'unsent lines while the whole tree is over the cap\n'
machine j
machine k
echo "transcripts on" >"$(home j)/.config/srcsync/config"
printf 'transcripts on\nmax_size 8K\n' >"$(home k)/.config/srcsync/config"
github_repo app4 j src/app4
git clone -q "$GHURL/app4.git" "$(home k)/src/app4" 2>/dev/null
JP=$(projects j src/app4)
KP=$(projects k src/app4)
mkdir -p "$JP" "$KP"
echo '{"j":1}' >"$JP/s1.jsonl"
on j publish
on k publish
on k apply
on k publish
on j apply
for n in 1 2 3 4 5; do head -c 3000 /dev/urandom | base64 >"$KP/h$n.jsonl"; done
echo '{"k":9}' >>"$KP/s1.jsonl"
on k publish
on j apply
echo '{"k":10}' >>"$KP/s1.jsonl"
on k publish
echo '{"j":9}' >>"$JP/s1.jsonl"
echo '{"j":0}' >"$JP/s2.jsonl"
on j publish
: >"$WORK/k.log"
on k apply
assert_eq "$(printf '{"j":1}\n{"k":9}\n{"k":10}')" "$(cat "$KP/s1.jsonl")" "k loses no unsent line"
assert_eq '{"j":0}' "$(cat "$KP/s2.jsonl" 2>&1)" "and still gets j's new file"
assert_eq 1 "$(grep -c "src/app4: kept s1.jsonl: both machines added to it" "$WORK/k.log")" \
	"and says so"
assert_eq "" "$(grep 'src/app4: .*left alone' "$WORK/k.log")" "with no conflict"
four() {
	on j publish
	on k publish
	on k apply
	on j apply
}
four
TOOK=$(cat "$WORK/j.log" "$WORK/k.log" | grep -c 'src/app4: took')
four
four
assert_eq "$TOOK" "$(cat "$WORK/j.log" "$WORK/k.log" | grep -c 'src/app4: took')" "and nothing applies again"
assert_eq "$(printf '{"j":1}\n{"k":9}\n{"k":10}')" "$(cat "$KP/s1.jsonl")" "k's lines are still there"

printf 'lay_claude judges each file by content alone\n'
machine u
git clone -q "$GHURL/app.git" "$(home u)/src/app" 2>/dev/null
U=$(projects u src/app)
T=$WORK/u-theirs
mkdir -p "$U/memory" "$T/memory"
printf '{"n":1}\n' >"$T/new.jsonl"
printf '{"n":1}\n' >"$U/same.jsonl"
cp "$U/same.jsonl" "$T/same.jsonl"
printf '{"n":1}\n' >"$U/grow.jsonl"
printf '{"n":1}\n{"n":2}\n' >"$T/grow.jsonl"
printf '{"n":1}\n{"n":2}\n' >"$U/short.jsonl"
printf '{"n":1}\n' >"$T/short.jsonl"
printf '{"n":1}\n{"u":1}\n' >"$U/fork.jsonl"
printf '{"n":1}\n{"t":1}\n' >"$T/fork.jsonl"
printf '{"n":1}\n{"u":1}\n' >"$U/long.jsonl"
printf '{"n":1}\n{"t":11}\n{"t":2}\n' >"$T/long.jsonl"
echo "u's" >"$U/memory/MEMORY.md"
echo "theirs" >"$T/memory/MEMORY.md"
printf 'one\n' >"$U/memory/cut.md"
printf 'one\ntwo\n' >"$T/memory/cut.md"
: >"$U/empty.jsonl"
printf '{"n":1}\n' >"$T/empty.jsonl"
touch -t 202001010000 "$U/same.jsonl"
UT=$(GIT_INDEX_FILE=$WORK/u-index git -C "$(home u)/src/app" --work-tree="$T" add -A . &&
	GIT_INDEX_FILE=$WORK/u-index git -C "$(home u)/src/app" write-tree)
mkdir -p "$(state u)"
OUT=$(lib u lay_claude "$(home u)/src/app" "$(home u)/src/app" "$UT" 2>&1)
assert_eq '{"n":1}' "$(cat "$U/new.jsonl" 2>&1)" "a file absent here is written"
assert_eq 202001010000 "$(date -r "$U/same.jsonl" +%Y%m%d%H%M)" "an identical file is not rewritten"
assert_eq "$(cat "$T/grow.jsonl")" "$(cat "$U/grow.jsonl")" "a file theirs extends is written"
assert_eq "$(printf '{"n":1}\n{"n":2}')" "$(cat "$U/short.jsonl")" "a file that extends theirs is kept"
assert_eq "$(printf '{"n":1}\n{"u":1}')" "$(cat "$U/fork.jsonl")" "a file both added to is kept"
assert_eq "$(printf '{"n":1}\n{"u":1}')" "$(cat "$U/long.jsonl")" "even when theirs is longer"
assert_eq "u's" "$(cat "$U/memory/MEMORY.md")" "a memory file that differs is kept"
assert_eq one "$(cat "$U/memory/cut.md")" "even when theirs extends it, since a cut line looks the same"
assert_eq '{"n":1}' "$(cat "$U/empty.jsonl")" "an empty transcript is extended"
assert_eq "$(printf '%s\n' memory/MEMORY.md memory/cut.md | LC_ALL=C sort)" \
	"$(sed -n 's/^srcsync: src\/app: kept \(.*\): it differs here$/\1/p' <<<"$OUT" | LC_ALL=C sort)" \
	"kept memory files are logged"
assert_eq "$(printf '%s\n' fork.jsonl long.jsonl short.jsonl)" \
	"$(sed -n 's/^srcsync: src\/app: kept \(.*\): both machines added to it$/\1/p' <<<"$OUT" | sort)" \
	"each kept file is logged once"

# The next three are the ways the recorded base and claude fields led an apply
# to overwrite lines: each asserts every line survives on both machines, and
# that a few more cycles apply nothing.
# Each pair gets a fresh hub, so its machines do not apply every earlier repo.
repro() { # m1 m2 repo
	rm -rf "$GH/hub.git"
	git init -q --bare "$GH/hub.git"
	machine "$1"
	machine "$2"
	echo "transcripts on" >"$(home "$1")/.config/srcsync/config"
	printf 'transcripts on\nmax_size 8K\n' >"$(home "$2")/.config/srcsync/config"
	github_repo "$3" "$1" "src/$3"
	git clone -q "$GHURL/$3.git" "$(home "$2")/src/$3" 2>/dev/null
	JP=$(projects "$1" "src/$3")
	KP=$(projects "$2" "src/$3")
	mkdir -p "$JP" "$KP"
	echo '{"j":1}' >"$JP/s1.jsonl"
	on "$1" publish
	on "$2" publish
	on "$2" apply
	on "$2" publish
	on "$1" apply
}
# The second machine's whole tree goes over the cap while both append to s1.
split_s1() { # j k
	for n in 1 2 3 4 5; do head -c 3000 /dev/urandom | base64 >"$KP/h$n.jsonl"; done
	echo '{"k":9}' >>"$KP/s1.jsonl"
	on "$2" publish
	on "$1" apply
	echo '{"k":10}' >>"$KP/s1.jsonl"
	on "$2" publish
	echo '{"j":9}' >>"$JP/s1.jsonl"
	on "$1" publish
	on "$2" apply
}
settles() { # j k repo
	local n took
	for n in 1 2; do
		on "$2" publish
		on "$1" apply
		on "$1" publish
		on "$2" apply
	done
	took=$(cat "$WORK/$1.log" "$WORK/$2.log" | grep -c "src/$3: took")
	for n in 1 2; do
		on "$2" publish
		on "$1" apply
		on "$1" publish
		on "$2" apply
	done
	assert_eq "$took" "$(cat "$WORK/$1.log" "$WORK/$2.log" | grep -c "src/$3: took")" "then nothing applies again"
}
lines_in() { # file lines...
	local f=$1 l missing=
	shift
	for l in "$@"; do grep -qxF "$l" "$f" || missing="$missing $l"; done
	echo "${missing:-all there}"
}

printf 'q raises its cap after keeping unsent lines\n'
repro p q app5
split_s1 p q
printf 'transcripts on\nmax_size 1M\n' >"$(home q)/.config/srcsync/config"
settles p q app5
assert_eq "all there" "$(lines_in "$JP/s1.jsonl" '{"j":1}' '{"j":9}')" "p keeps its lines"
assert_eq "all there" "$(lines_in "$KP/s1.jsonl" '{"j":1}' '{"k":9}' '{"k":10}')" "q keeps its lines"

printf 's falls under the cap on its own after keeping unsent lines\n'
repro r s app6
split_s1 r s
for n in 1 2 3 4 5; do head -c 7000 /dev/urandom | base64 >>"$KP/h$n.jsonl"; done
settles r s app6
assert_eq "all there" "$(lines_in "$JP/s1.jsonl" '{"j":1}' '{"j":9}')" "r keeps its lines"
assert_eq "all there" "$(lines_in "$KP/s1.jsonl" '{"j":1}' '{"k":9}' '{"k":10}')" "s keeps its lines"

printf 'v raises its cap over a file it left out\n'
repro t v app7
head -c 7000 /dev/urandom | base64 >"$JP/s0.jsonl"
on t publish
on v apply
on v publish
on t apply
echo '{"j":9}' >>"$JP/s0.jsonl"
on t publish
on v apply
on v publish
on t apply
printf 'transcripts on\nmax_size 1M\n' >"$(home v)/.config/srcsync/config"
settles t v app7
assert_eq "all there" "$(lines_in "$JP/s0.jsonl" '{"j":9}')" "t keeps its line in s0"
assert_eq "$(cat "$JP/s0.jsonl")" "$(cat "$KP/s0.jsonl" 2>&1)" "and v's s0 catches up"
assert_eq "" "$(cat "$WORK/t.log" "$WORK/v.log" | grep 'src/app7: .*left alone')" "with no conflict"

done_testing
