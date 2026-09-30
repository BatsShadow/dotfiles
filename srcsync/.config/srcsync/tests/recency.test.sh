#!/usr/bin/env bash
# A full publish walks every worktree under ~/src and takes minutes on the
# main machine, and a run cut short by the lid closing used to make none of
# its work visible. So publish visits worktrees newest first across repos, and
# srcsync never bumps the signals it reads that order from.
#
#   ./recency.test.sh

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# A git that logs the worktree of every snapshot it commits, in order.
REALGIT=$(command -v git)
mkdir -p "$WORK/bin"
cat >"$WORK/bin/git" <<G
#!/bin/bash
[ "\$1" = -C ] && [ "\$3" = commit-tree ] && echo "\$2" >>"$WORK/commit-tree.log"
exec $REALGIT "\$@"
G
chmod +x "$WORK/bin/git"

# Sets the mtime of a worktree's git file, index or logs/HEAD, to $3.
stamp() { # machine dir git-path touch-time
	touch -t "$4" "$(g "$1" "$2" rev-parse --path-format=absolute --git-path "$3")"
}

# The projects dir Claude files a worktree's transcripts under.
projects_of() { # machine dir
	echo "$(home "$1")/.claude/projects/$(printf '%s' "$(home "$1")/$2" | tr -c 'A-Za-z0-9' '-')"
}

machine a
github_repo app a src/app
github_repo lib a src/lib
g a src/app worktree add -q -b spike "$(home a)/src/app-wt"
on a publish

printf 'publish visits the newest worktree first, across repos\n'

echo "app" >>"$(home a)/src/app/README"
echo "app-wt" >>"$(home a)/src/app-wt/README"
echo "lib" >>"$(home a)/src/lib/README"
for d in src/app src/app-wt src/lib; do
	stamp a $d index 202001010000
	stamp a $d logs/HEAD 202001010000
done
# one signal each: app-wt's index, a transcript in lib, a commit in app
stamp a src/app-wt index 202503010000
mkdir -p "$(projects_of a src/lib)"
touch -t 202502010000 "$(projects_of a src/lib)/s.jsonl"
stamp a src/app logs/HEAD 202501010000
: >"$WORK/commit-tree.log"
PATH="$WORK/bin:$PATH" on a publish
assert_eq "$(home a)/src/app-wt
$(home a)/src/lib
$(home a)/src/app" "$(cat "$WORK/commit-tree.log")" "worktrees are snapshotted newest first"

last=$(home a)/.local/state/srcsync/last.json
assert_eq "src/app src/lib" "$(jq -r '.repos | keys_unsorted | join(" ")' "$last")" \
	"repos are still written in the order they are found"
assert_eq "src/app src/app-wt" "$(jq -r '.repos["src/app"].worktrees | keys_unsorted | join(" ")' "$last")" \
	"and worktrees in the order git lists them"

printf 'publish leaves the index alone\n'

# A clone of someone else's project is routed by whether it has changes,
# which git status reads. Left to itself, status refreshes a stale index and
# rewrites it, and that write would read as the user touching the worktree.
machine c
echo "owner nobody" >"$(home c)/.config/srcsync/config"
github_repo lent c src/lent
echo "wip" >"$(home c)/src/lent/untracked"
touch "$(home c)/src/lent/README"
stamp c src/lent index 202001010000
before=$(stat -f %m "$(g c src/lent rev-parse --path-format=absolute --git-path index)")
on c publish
assert_eq "true" "$(jq -r '.repos | has("src/lent")' "$(home c)/.local/state/srcsync/last.json")" \
	"a dirty clone of someone else's project is published"
assert_eq "$before" "$(stat -f %m "$(g c src/lent rev-parse --path-format=absolute --git-path index)")" \
	"without touching its index"

done_testing
