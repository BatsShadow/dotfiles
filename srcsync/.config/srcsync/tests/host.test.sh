#!/usr/bin/env bash
# The host id names a machine's file on the hub and its refs, so it must not
# follow a name the network can change. It is resolved once and kept in the
# state dir. A renamed machine that re-read hostname every run saw its own old
# file as another machine's and rolled its worktree back and forth each run.
#
#   ./host.test.sh

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# scutil and hostname stubs that report whatever $WORK/name-<machine> says,
# the way a Bonjour clash or a DHCP name would change them.
mkdir -p "$WORK/bin"
cat >"$WORK/bin/scutil" <<'EOF'
#!/bin/bash
[ "$*" = "--get LocalHostName" ] || exit 1
[ -s "$NAME_FILE.scutil" ] || exit 1
cat "$NAME_FILE.scutil"
EOF
cat >"$WORK/bin/hostname" <<'EOF'
#!/bin/bash
cat "$NAME_FILE"
EOF
chmod +x "$WORK/bin/scutil" "$WORK/bin/hostname"

# Runs srcsync as machine $1 with no SRCSYNC_HOST, so the id comes from the
# stubs or the state dir.
named() { # machine command
	local m=$1
	shift
	own "$m"
	HOME=$WORK/$m SRCSYNC_HUB=$GH/hub.git NAME_FILE=$WORK/name-$m PATH=$WORK/bin:$PATH \
		/bin/bash "$SRCSYNC" "$@" 2>>"$WORK/$m.log"
}

machine a
machine b
echo a >"$WORK/name-a.scutil"
echo a-dhcp >"$WORK/name-a"
echo b >"$WORK/name-b.scutil"
echo b >"$WORK/name-b"
github_repo app a src/app
git clone -q "$GHURL/app.git" "$(home b)/src/app" 2>/dev/null

printf 'the id is resolved once\n'

named a publish
named b publish
named b apply
named a apply
assert_eq a "$(cat "$(home a)/.local/state/srcsync/host" 2>/dev/null)" "a keeps LocalHostName as its id"
assert_eq "a b" "$(ls "$(home a)/.local/state/srcsync/hub/machines" | sed 's/\.json$//' | tr '\n' ' ' | sed 's/ $//')" \
	"the hub has one file per machine"

echo "X1" >"$(home a)/src/app/work.txt"
named a publish
named b apply
echo "Y" >>"$(home b)/src/app/work.txt"
named b publish
named a apply
assert_eq "X1
Y" "$(cat "$(home a)/src/app/work.txt")" "a has b's work"

printf 'a name change does not change the id\n'

echo a2 >"$WORK/name-a.scutil"
echo a2 >"$WORK/name-a"
: >"$WORK/a.log"
before=$(g a src/app reflog refs/srcsync-local/src/app/before-apply 2>/dev/null | wc -l | tr -d ' ')
for _ in 1 2 3; do
	named a publish
	named a apply
done
assert_eq 0 "$(grep -c 'took' "$WORK/a.log")" "three runs after the rename take nothing"
assert_eq "$before" "$(g a src/app reflog refs/srcsync-local/src/app/before-apply 2>/dev/null | wc -l | tr -d ' ')" \
	"and save nothing before an apply"
assert_eq "X1
Y" "$(cat "$(home a)/src/app/work.txt")" "a's worktree stays as it was"
assert_eq no "$([ -e "$(home a)/.local/state/srcsync/hub/machines/a2.json" ] && echo yes || echo no)" \
	"no second file for a appears on the hub"

printf 'without LocalHostName, hostname -s\n'

machine c
echo c-short >"$WORK/name-c"
named c status >/dev/null
assert_eq c-short "$(cat "$(home c)/.local/state/srcsync/host" 2>/dev/null)" "c falls back to hostname"

printf 'SRCSYNC_HOST wins\n'

machine d
echo d-name >"$WORK/name-d"
own d
HOME=$WORK/d SRCSYNC_HOST=override SRCSYNC_HUB=$GH/hub.git NAME_FILE=$WORK/name-d PATH=$WORK/bin:$PATH \
	/bin/bash "$SRCSYNC" publish 2>>"$WORK/d.log"
assert_eq override "$(jq -r .host "$(home d)/.local/state/srcsync/last.json")" "the env var names the machine"

printf 'a machine that published before the id was kept keeps its name\n'
machine e
echo e-new >"$WORK/name-e.scutil"
echo e-new >"$WORK/name-e"
mkdir -p "$(home e)/.local/state/srcsync"
echo '{"host": "e-old", "worktrees": {}}' >"$(home e)/.local/state/srcsync/last.json"
named e publish
assert_eq e-old "$(cat "$(home e)/.local/state/srcsync/host" 2>/dev/null)" "e takes its id from last.json"

printf "an entry under this machine's own id is never applied\n"

# Two machines reporting one name write one file. Neither may take the
# other's entry as its own machine's, or the two would overwrite each other.
echo a >"$WORK/name-b.scutil"
rm -f "$(home b)/.local/state/srcsync/host" "$(home b)/.local/state/srcsync/last.json"
echo "b's clash" >"$(home b)/src/app/clash"
named b publish
: >"$WORK/a.log"
named a apply
assert_eq no "$([ -e "$(home a)/src/app/clash" ] && echo yes || echo no)" "a does not apply a file under its own id"

done_testing
