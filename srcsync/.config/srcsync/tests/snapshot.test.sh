#!/usr/bin/env bash
# Reading a worktree's state must leave it exactly as it was: the index, HEAD
# and the stash are the user's, and a snapshot runs every few minutes while
# they work. And what it reads must be everything but ignored and excluded
# files, because the excluded ones are the secrets.
#
#   ./snapshot.test.sh

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

machine a
github_repo app a src/app
R=$(home a)/src/app
cat >"$(home a)/.config/srcsync/config" <<'CFG'
exclude .env
exclude *.pem
CFG

printf 'reading leaves the worktree alone\n'

echo "staged" >"$R/staged"
g a src/app add staged
echo "edit" >>"$R/README"
echo "untracked" >"$R/untracked"
g a src/app stash list >"$WORK/stash.before"
index_before=$(g a src/app ls-files --stage | shasum)
head_before=$(g a src/app rev-parse HEAD)
status_before=$(changes a src/app)

tree=$(lib a worktree_tree "$R")

assert_eq "$index_before" "$(g a src/app ls-files --stage | shasum)" "the index is unchanged"
assert_eq "$head_before" "$(g a src/app rev-parse HEAD)" "HEAD is unchanged"
assert_eq "$status_before" "$(changes a src/app)" "git status is unchanged"
assert_eq "$(cat "$WORK/stash.before")" "$(g a src/app stash list)" "the stash is unchanged"

printf 'what the tree holds\n'

files=$(g a src/app ls-tree -r --name-only "$tree" | tr '\n' ' ')
assert_eq "README staged untracked " "$files" "tracked, staged and untracked files, flattened"

echo "SECRET=1" >"$R/.env"
mkdir -p "$R/config"
echo "key" >"$R/config/server.pem"
echo "ignored" >"$R/build.log"
echo "*.log" >"$R/.gitignore"
g a src/app add .gitignore
files=$(g a src/app ls-tree -r --name-only "$(lib a worktree_tree "$R")" | tr '\n' ' ')
assert_eq ".gitignore README staged untracked " "$files" \
	"ignored files, and excluded ones at any depth, are left out"

g a src/app add -f .env
files=$(g a src/app ls-tree -r --name-only "$(lib a worktree_tree "$R")" | tr '\n' ' ')
assert_eq ".gitignore README staged untracked " "$files" \
	"an excluded file that is only staged is still left out"

g a src/app commit -q -m "commit the env file"
files=$(g a src/app ls-tree -r --name-only "$(lib a worktree_tree "$R")" | tr '\n' ' ')
assert_eq ".env .gitignore README staged untracked " "$files" \
	"one already committed stays, or the snapshot would delete it"

printf 'an excluded directory\n'

echo "exclude secrets" >>"$(home a)/.config/srcsync/config"
mkdir -p "$R/secrets" "$R/a/b/secrets"
echo "key" >"$R/secrets/key.txt"
echo "key" >"$R/a/b/secrets/k2"
files=$(g a src/app ls-tree -r --name-only "$(lib a worktree_tree "$R")" | tr '\n' ' ')
assert_eq ".env .gitignore README staged untracked " "$files" \
	"its files are left out, at any depth"
g a src/app add secrets
files=$(g a src/app ls-tree -r --name-only "$(lib a worktree_tree "$R")" | tr '\n' ' ')
assert_eq ".env .gitignore README staged untracked " "$files" \
	"even when only staged"
g a src/app rm -rq --cached secrets
rm -rf "$R/secrets" "$R/a"

printf 'state\n'

IFS=$'\t' read -r branch head tracking _ <<<"$(lib a worktree_state "$R")"
assert_eq "main $(g a src/app rev-parse HEAD) origin/main" "$branch $head $tracking" \
	"branch, head and tracking ref"
g a src/app switch -q --detach
IFS=$'\t' read -r branch _ tracking _ <<<"$(lib a worktree_state "$R")"
assert_eq "- -" "$branch $tracking" "a detached worktree has neither"

git init -q "$(home a)/src/empty"
lib a worktree_state "$(home a)/src/empty" >/dev/null 2>&1
assert_eq 1 "$?" "a repo with no commits has no state"

done_testing
