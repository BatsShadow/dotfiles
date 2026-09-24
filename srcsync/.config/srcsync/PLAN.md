# srcsync engine implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the srcsync engine: `publish`, `apply`, `sync` and `status`, run by hand, carrying repos, worktrees and uncommitted work between two machines.

**Architecture:** One bash entry point, `srcsync.sh`, sources four libraries. `snapshot.sh` turns a worktree into a commit without touching it. `publish.sh` snapshots every worktree under `~/src`, pushes the snapshots and writes this machine's state file to the hub repo. `apply.sh` reads the other machine's state file and asks `decide.jq`, a pure function, what to do with each worktree.

**Tech Stack:** bash 3.2 (`/bin/bash`), git 2.54, jq 1.6. Tests are standalone bash executables that drive real git against bare repos in a temp dir.

**Spec:** `srcsync/.config/srcsync/DESIGN.md`. Read it first. Task 5 amends it where building the engine showed the spec was wrong.

## Global constraints

- Every path below is relative to the dotfiles repo root. The package is `srcsync/.config/srcsync/` and stows to `~/.config/srcsync/`.
- Scripts run under `/bin/bash`, which is 3.2 on macOS, because launchd agents get a PATH that finds it before Homebrew's bash. No associative arrays, no `mapfile`, and every array that may be empty is expanded as `${a[@]+"${a[@]}"}`. The tests run srcsync under `/bin/bash` so a slip fails there.
- jq is 1.6. Nothing added in 1.7, such as `pick`, `abs` or `have_decnum`.
- A repo with any remote URL matching a `company` pattern never sends anything to the hub, through any override.
- Snapshots never touch the working tree, the index, HEAD or the stash.
- Refs are `refs/srcsync/<host>/<path from $HOME>/tree`. The hub is `git@github.com-batsshadow:BatsShadow/srcsync-state.git`. State lives in `~/.local/state/srcsync/`.
- Tests use real git. No stubs.
- Writing rules in `claude/.claude/references/unslop.md` apply to comments and commit messages. Comments say why, and match the length of their neighbours.
- Ask the user before every commit. The commit steps below give the message to propose.

## Scope

This plan is the engine only. Three later plans build on it:

1. Claude transcripts, the `claude` ref, and restarting an idle Claude after an apply. Needs checks 1, 2 and 4 from DESIGN.md first.
2. Triggers: the launchd agent (following the kanata plist), Stop and SessionEnd hooks merged by `install-hooks.sh`, sleepwatcher (check 5, and it is not installed yet), and the sessionizer calling apply.
3. The tmux status bar conflict mark and the picker.

## Files

| Path under `srcsync/.config/srcsync/` | What it does |
| --- | --- |
| `srcsync.sh` | Entry point. Loads config, takes the lock, dispatches. |
| `lib/common.sh` | Paths, config parsing, routing (`sync_target`), the lock. |
| `lib/snapshot.sh` | Worktree to tree and commit, worktree state, push size. |
| `lib/decide.jq` | The apply rule as a pure function. |
| `lib/publish.sh` | Finds repos and worktrees, builds the state file, pushes. |
| `lib/apply.sh` | Reads the other machine's state and applies it. |
| `config` | Company and team patterns, excludes, size cap. |
| `tests/lib.sh` | Two fake machines and a fake GitHub. |
| `tests/*.test.sh` | One executable per concern. |

---

### Task 1: Test harness, common library and snapshots

**Files:**
- Create: `srcsync/.config/srcsync/tests/lib.sh`
- Create: `srcsync/.config/srcsync/lib/common.sh`
- Create: `srcsync/.config/srcsync/lib/snapshot.sh`
- Test: `srcsync/.config/srcsync/tests/snapshot.test.sh`

**Interfaces:**
- Produces, in `tests/lib.sh`: `machine m`, `home m`, `on m command`, `g m dir git-args`, `github_repo name m path`, `refs_in name`, `session m status dir pid`, `changes m dir`, `lib m function args`, `assert_eq want got label`, `done_testing`. `$WORK` is the temp root, `$GH` holds the bare repos, `$WORK/<m>.log` collects what srcsync says on stderr.
- Produces, in `lib/common.sh`: variables `SRCSYNC_HOST SRCSYNC_HUB SRCSYNC_CONFIG SRCSYNC_STATE SRCSYNC_SRC CC_SESSIONS_DIR HOME_P LAST HUB_DIR PENDING HUB_PENDING CONFLICTS LAST_SUCCESS CFG_COMPANY CFG_TEAM CFG_EXCLUDE CFG_OVERRIDES CFG_MAX_SIZE`; functions `say msg`, `now`, `load_config`, `matches_any text patterns`, `key_of abs_path` (path from `$HOME`, fails outside it), `snap_ref host key`, `sync_target repo_dir key` (prints `hub`, `origin` or `skip:<reason>`), `target_url hub|origin`, `take_lock`, `ensure_last`, `mark_pending repo_key` (queues the repo for `push_pending`), `to_bytes size`.
- Produces, in `lib/snapshot.sh`: `exclude_specs magic` (the excludes as pathspecs), `worktree_tree dir` (prints a tree sha), `worktree_state dir` (prints `branch head tracking tree` tab-separated, `-` for none, fails with no commits), `state_json branch head tracking tree`, `on_remote dir commit`, `make_snapshot dir key tree head branch tracking` (prints a commit sha), `push_size repo_dir snapshot target` (bytes).

- [ ] **Step 1: Write the harness**

`srcsync/.config/srcsync/tests/lib.sh`:

```bash
# Two machines side by side for the srcsync tests. Each machine is a $HOME with
# its own ~/src, state and Claude sessions dir, and GitHub is a directory of
# bare repos. Real git throughout: what srcsync rests on are facts about git,
# and a stub would assert them into existence.
#
# srcsync runs under /bin/bash, the 3.2 that launchd will find, so anything
# newer that slips into lib/ fails here first.

set -u

TESTS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
SRCSYNC=$(cd "$TESTS/.." && pwd -P)/srcsync.sh

WORK=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$WORK"' EXIT
GH=$WORK/github
mkdir -p "$GH"

export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=$WORK/gitconfig
cat >"$GIT_CONFIG_GLOBAL" <<'EOF'
[user]
	name = srcsync test
	email = test@example.com
[init]
	defaultBranch = main
[advice]
	detachedHead = false
EOF

PASS=0
FAIL=0
pass() {
	PASS=$((PASS + 1))
	printf '  ok   %s\n' "$1"
}
fail() {
	FAIL=$((FAIL + 1))
	printf '  FAIL %s\n' "$1"
	shift
	local l
	for l in "$@"; do printf '         %s\n' "$l"; done
}
assert_eq() { # want got label
	if [ "$1" = "$2" ]; then pass "$3"; else
		fail "$3" "expected: $(printf '%q' "$1")" "got:      $(printf '%q' "$2")"
	fi
}
done_testing() {
	printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
	[ "$FAIL" -eq 0 ]
}

git init -q --bare "$GH/hub.git"

# A machine's $HOME.
home() { echo "$WORK/$1"; }
machine() {
	mkdir -p "$WORK/$1/src" "$WORK/$1/.claude/sessions" "$WORK/$1/.config/srcsync"
}

# Runs srcsync as machine $1. stderr, where srcsync reports, goes to
# $WORK/<machine>.log so a test can check what it said.
on() { # machine command
	local m=$1
	shift
	HOME=$WORK/$m SRCSYNC_HOST=$m SRCSYNC_HUB=$GH/hub.git \
		/bin/bash "$SRCSYNC" "$@" 2>>"$WORK/$m.log"
}

# Runs git as machine $1 in the directory ~/$2.
g() { # machine dir git-args
	local m=$1 d=$2
	shift 2
	git -C "$WORK/$m/$d" "$@"
}

# A GitHub repo with one commit on main, cloned onto machine $2 at ~/$3.
github_repo() { # name machine path
	git init -q --bare "$GH/$1.git"
	git clone -q "$GH/$1.git" "$WORK/$2/$3" 2>/dev/null
	echo "hello" >"$WORK/$2/$3/README"
	g "$2" "$3" add README
	g "$2" "$3" commit -q -m "first"
	g "$2" "$3" push -q origin main
}

# Every srcsync ref a bare repo holds, as "sha ref" lines.
refs_in() { git -C "$GH/$1.git" for-each-ref --format='%(objectname) %(refname)' refs/srcsync; }

# A Claude session file on machine $1, with status $2 in ~/$3, owned by $4.
session() { # machine status dir pid
	jq -n --arg s "$2" --arg c "$WORK/$1/$3" --argjson p "$4" \
		'{pid: $p, status: $s, cwd: $c}' >"$WORK/$1/.claude/sessions/$4.json"
}

# The status line git would show for ~/$2 on machine $1, one file per line.
changes() { g "$1" "$2" status --porcelain=v1 --untracked-files=all | sort; }

# Calls one lib function as machine $1, under the same /bin/bash.
lib() { # machine function args
	local m=$1
	shift
	HOME=$WORK/$m SRCSYNC_HOST=$m SRCSYNC_HUB=$GH/hub.git LIB=$TESTS/../lib /bin/bash -c '
		set -u
		. "$LIB/common.sh"; . "$LIB/snapshot.sh"
		load_config
		"$@"' _ "$@"
}
```

- [ ] **Step 2: Write the failing test**

`srcsync/.config/srcsync/tests/snapshot.test.sh`, executable:

```bash
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
```

- [ ] **Step 3: Run it and see it fail**

Run: `chmod +x srcsync/.config/srcsync/tests/snapshot.test.sh && srcsync/.config/srcsync/tests/snapshot.test.sh`
Expected: `4 passed, 7 failed`. The four that pass check that nothing moved, which holds trivially when nothing ran.

- [ ] **Step 4: Write `lib/common.sh`**

```bash
# Shared by every srcsync command: where things live, the config, the lock, and
# which remote a repo's snapshots may go to.
#
# Everything hangs off $HOME so the tests can stand two machines side by side
# as two directories. Written for /bin/bash 3.2, because launchd runs agents
# with a PATH that finds that one and not Homebrew's: no associative arrays, no
# mapfile, and every possibly-empty array expanded as ${a[@]+"${a[@]}"}, which
# 3.2 otherwise reports as unbound under set -u.

SRCSYNC_HOST=${SRCSYNC_HOST:-$(hostname -s)}
SRCSYNC_HUB=${SRCSYNC_HUB:-git@github.com-batsshadow:BatsShadow/srcsync-state.git}
SRCSYNC_CONFIG=${SRCSYNC_CONFIG:-$HOME/.config/srcsync/config}
SRCSYNC_STATE=${SRCSYNC_STATE:-$HOME/.local/state/srcsync}
SRCSYNC_SRC=${SRCSYNC_SRC:-$HOME/src}
CC_SESSIONS_DIR=${CC_SESSIONS_DIR:-$HOME/.claude/sessions}

# git reports physical paths, so keys are cut from the physical $HOME. On a
# Mac /Users/scott has no symlink in it; the tests' temp dirs under /var do.
HOME_P=$(cd "$HOME" && pwd -P)

LAST=$SRCSYNC_STATE/last.json
HUB_DIR=$SRCSYNC_STATE/hub
PENDING=$SRCSYNC_STATE/pending
HUB_PENDING=$SRCSYNC_STATE/hub-pending
CONFLICTS=$SRCSYNC_STATE/conflicts.json
LAST_SUCCESS=$SRCSYNC_STATE/last-success

say() { printf 'srcsync: %s\n' "$*" >&2; }

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

CFG_COMPANY=""
CFG_TEAM=""
CFG_EXCLUDE=""
CFG_OVERRIDES=""
CFG_MAX_SIZE=$((50 * 1048576))

to_bytes() {
	case $1 in
	*K) echo $((${1%K} * 1024)) ;;
	*M) echo $((${1%M} * 1048576)) ;;
	*G) echo $((${1%G} * 1073741824)) ;;
	*) echo "$1" ;;
	esac
}

# One setting per line, `keyword value [value]`, # for comments:
#   company  <substring of a remote URL>
#   team     <substring of a team repo's URL>
#   exclude  <gitignore-style name>
#   max_size <bytes, or with K, M or G>
#   sync     <path from $HOME> hub|origin|skip
load_config() {
	local kw a b nl=$'\n'
	[ -f "$SRCSYNC_CONFIG" ] || return 0
	while read -r kw a b; do
		case $kw in
		'' | \#*) ;;
		company) CFG_COMPANY=$CFG_COMPANY$a$nl ;;
		team) CFG_TEAM=$CFG_TEAM$a$nl ;;
		exclude) CFG_EXCLUDE=$CFG_EXCLUDE$a$nl ;;
		max_size) CFG_MAX_SIZE=$(to_bytes "$a") ;;
		sync) CFG_OVERRIDES=$CFG_OVERRIDES$a$'\t'$b$nl ;;
		*) say "config: unknown keyword '$kw'" ;;
		esac
	done <"$SRCSYNC_CONFIG"
}

# True when any line of $1 contains any pattern in the list $2.
matches_any() { # text patterns
	local p
	while IFS= read -r p; do
		[ -n "$p" ] || continue
		case $1 in *"$p"*) return 0 ;; esac
	done <<EOF
$2
EOF
	return 1
}

# Path from $HOME for an absolute path, failing for one outside it.
key_of() {
	case $1 in
	"$HOME_P"/*) printf '%s\n' "${1#"$HOME_P"/}" ;;
	*) return 1 ;;
	esac
}

snap_ref() { # host key
	printf 'refs/srcsync/%s/%s/tree\n' "$1" "$2"
}

# hub, origin, or skip:<reason>. The company test runs first and returns, so no
# override below it can send a company repo to the personal hub.
sync_target() { # repo_dir key
	local urls origin override
	urls=$(git -C "$1" remote -v | awk '{print $2}' | sort -u)
	if matches_any "$urls" "$CFG_COMPANY"; then
		origin=$(git -C "$1" remote get-url origin 2>/dev/null) || {
			echo "skip:company repo with no origin"
			return
		}
		if matches_any "$origin" "$CFG_TEAM"; then
			echo "skip:origin is the team repo, fork it first"
			return
		fi
		echo origin
		return
	fi
	override=$(printf '%s' "$CFG_OVERRIDES" | awk -F'\t' -v k="$2" '$1 == k { v = $2 } END { print v }')
	case $override in
	skip) echo "skip:config says skip" ;;
	origin)
		if git -C "$1" remote get-url origin >/dev/null 2>&1; then echo origin; else echo hub; fi
		;;
	*) echo hub ;;
	esac
}

# The push URL for a target, run from inside the repo.
target_url() {
	if [ "$1" = hub ]; then echo "$SRCSYNC_HUB"; else echo origin; fi
}

# One run at a time. macOS has no flock, and mkdir is atomic. A lock whose
# holder is dead is taken over; one with no pid yet is only stale after a
# minute, because the holder writes its pid a moment after the mkdir.
take_lock() {
	local lock=$SRCSYNC_STATE/lock pid
	mkdir -p "$SRCSYNC_STATE"
	if ! mkdir "$lock" 2>/dev/null; then
		pid=$(cat "$lock/pid" 2>/dev/null)
		if [ -n "$pid" ]; then
			kill -0 "$pid" 2>/dev/null && return 1
		elif [ -z "$(find "$lock" -maxdepth 0 -mmin +1)" ]; then
			return 1
		fi
		rm -rf "$lock"
		mkdir "$lock" 2>/dev/null || return 1
	fi
	echo $$ >"$lock/pid"
	trap 'rm -rf "$SRCSYNC_STATE/lock"' EXIT
}

# last.json, created empty if this machine has never published.
ensure_last() {
	mkdir -p "$SRCSYNC_STATE"
	[ -f "$LAST" ] || printf '{"host":"%s","repos":{}}\n' "$SRCSYNC_HOST" >"$LAST"
}

mark_pending() { # repo key
	grep -qxF "$1" "$PENDING" 2>/dev/null || echo "$1" >>"$PENDING"
}
```

- [ ] **Step 5: Write `lib/snapshot.sh`**

```bash
# Reading a worktree's state without disturbing it, and writing it down as one
# commit. See DESIGN.md "Snapshots".

# The configured excludes as pathspecs matching at any depth. $1 is the magic:
# "exclude,glob" to leave them out of an add, "glob" to find them.
exclude_specs() { # magic
	local p
	while IFS= read -r p; do
		[ -n "$p" ] && printf ':(%s)**/%s\n' "$1" "$p"
	done <<EOF
$CFG_EXCLUDE
EOF
}

# The tree the worktree at $1 would snapshot to: tracked and untracked files,
# minus ignored and excluded ones. It works on a copy of the real index, so git
# add never writes to that, and the copy's stat cache spares rehashing every
# unchanged file on each run.
worktree_tree() { # dir
	local dir=$1 tmp real out=() in=() s
	tmp=$(mktemp "${TMPDIR:-/tmp}/srcsync-index.XXXXXX")
	real=$(git -C "$dir" rev-parse --path-format=absolute --git-path index)
	if [ -f "$real" ]; then cp "$real" "$tmp"; else rm -f "$tmp"; fi
	while IFS= read -r s; do out+=("$s"); done < <(exclude_specs exclude,glob)
	while IFS= read -r s; do in+=("$s"); done < <(exclude_specs glob)
	(
		cd "$dir" || exit 1
		export GIT_INDEX_FILE=$tmp
		[ -f "$tmp" ] || git read-tree HEAD || exit 1
		git add -A -- . ${out[@]+"${out[@]}"} || exit 1
		# An excluded file staged but never committed is still in the copy.
		# Drop it, but never one HEAD has: dropping that would publish a delete.
		if [ ${#in[@]} -gt 0 ]; then
			git diff --cached --name-only --diff-filter=A -z HEAD -- "${in[@]}" |
				xargs -0 git rm -q --cached --ignore-unmatch -- 2>/dev/null
		fi
		git write-tree
	)
	local rc=$?
	rm -f "$tmp"
	return $rc
}

# branch, head, tracking and tree, tab-separated, with "-" where there is no
# branch or no tracking ref. Fails for a repo with no commits yet.
worktree_state() { # dir
	local branch head tracking tree
	head=$(git -C "$1" rev-parse -q --verify 'HEAD^{commit}') || return 1
	branch=$(git -C "$1" symbolic-ref -q --short HEAD) || branch=-
	tracking=$(git -C "$1" rev-parse -q --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null) || tracking=-
	tree=$(worktree_tree "$1") || return 1
	printf '%s\t%s\t%s\t%s\n' "$branch" "$head" "$tracking" "$tree"
}

# The same state as a JSON object, with null for "-".
state_json() { # branch head tracking tree
	jq -cn --arg b "$1" --arg h "$2" --arg t "$3" --arg tr "$4" '
		def n: if . == "-" then null else . end;
		{branch: ($b | n), head: $h, tracking: ($t | n), tree: $tr}'
}

# True when some remote-tracking ref already contains $2, so another machine
# can get the commit without a snapshot.
on_remote() { # dir commit
	[ -n "$(git -C "$1" for-each-ref --count=1 --contains "$2" refs/remotes)" ]
}

# Commits tree $3 on top of head $4 without moving HEAD or any branch. The
# trailers let a snapshot be read without the state file.
make_snapshot() { # dir key tree head branch tracking
	git -C "$1" commit-tree "$3" -p "$4" -m "srcsync snapshot of $2

Srcsync-Path: $2
Srcsync-Branch: $5
Srcsync-Tracking: $6
Srcsync-Host: $SRCSYNC_HOST"
}

# Bytes on disk of every object pushing $2 would send: all it reaches that the
# target is not known to hold. The target holds every srcsync ref this repo
# has, and origin also holds its branches. The hub holds nothing else, so the
# first hub push of a cloned repo counts its whole history, which is exactly
# what the hub would receive.
push_size() { # repo_dir snapshot target
	local not=(--glob='refs/srcsync/*')
	[ "$3" = origin ] && not+=(--remotes=origin)
	git -C "$1" rev-list --objects --disk-usage "$2" --not "${not[@]}"
}
```

- [ ] **Step 6: Run the test and see it pass**

Run: `srcsync/.config/srcsync/tests/snapshot.test.sh`
Expected: `11 passed, 0 failed`

- [ ] **Step 7: Commit, after asking**

```bash
git add srcsync/.config/srcsync/tests/lib.sh srcsync/.config/srcsync/tests/snapshot.test.sh \
	srcsync/.config/srcsync/lib/common.sh srcsync/.config/srcsync/lib/snapshot.sh
git commit -m "Snapshot a srcsync worktree without touching it

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: The apply rule

**Files:**
- Create: `srcsync/.config/srcsync/lib/decide.jq`
- Test: `srcsync/.config/srcsync/tests/decide.test.sh`

**Interfaces:**
- Consumes: `tests/lib.sh` from Task 1.
- Produces: `lib/decide.jq`. Input is one object `{mine, now, theirs, removed_at, ff_forward, ff_back}`. `mine` and `theirs` are state-file worktree entries or null, `now` is `{branch, head, tracking, tree}` or null, `removed_at` is a timestamp string or null, the two `ff_` fields are booleans or null. Output is one raw string: `same`, `ahead`, `apply`, `conflict` or `check-ff`. Call it as `jq -cn '{...}' | jq -r -f decide.jq`. Passing the fields as `--argjson` to a `jq -n -f` call leaves `.now` and the rest null, and every answer comes out `apply`.

- [ ] **Step 1: Write the failing test**

`srcsync/.config/srcsync/tests/decide.test.sh`, executable:

```bash
#!/usr/bin/env bash
# The apply rule as a table. Each row is one situation between two machines and
# the one answer that keeps work from being lost: take theirs only when this
# side has nothing they lack, and call it a conflict when both have moved.
#
# States are named by letter. S0 is where both started, A1 and B1 are each
# side's first change, A2 builds on B1.
#
#   ./decide.test.sh

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DECIDE=$(cd "$TESTS/.." && pwd -P)/lib/decide.jq

st() { printf '{"branch":"main","head":"h-%s","tree":"t-%s"}' "$1" "$1"; }
# An entry: state $1, based on state $2 ("-" for none), changed at $3.
entry() {
	local base=null
	[ "$2" = - ] || base=$(st "$2")
	jq -c --argjson b "$base" --arg at "$3" '. + {snapshot: "s", changed_at: $at, base: $b}' <<<"$(st "$1")"
}

# mine now theirs removed_at ff_forward ff_back -> decision
row() { # want label mine now theirs [removed_at] [ff_forward] [ff_back]
	local got
	got=$(jq -cn --argjson mine "$3" --argjson now "$4" --argjson theirs "$5" \
		--argjson removed_at "${6:-null}" --argjson ff_forward "${7:-null}" --argjson ff_back "${8:-null}" \
		'{$mine, $now, $theirs, $removed_at, $ff_forward, $ff_back}' | jq -r -f "$DECIDE")
	assert_eq "$1" "$got" "$2"
}

printf 'the normal flow\n'
row same "both sides already match" \
	"$(entry S0 - 1)" "$(st S0)" "$(entry S0 - 1)"
row apply "they built on my latest, I have not touched it" \
	"$(entry S0 - 1)" "$(st S0)" "$(entry A1 S0 2)"
row apply "I only hold what I took from them, and they moved on" \
	"$(entry A1 A1 2)" "$(st A1)" "$(entry A2 - 3)"
row ahead "they have not moved since I took theirs" \
	"$(entry B1 A1 3)" "$(st B1)" "$(entry A1 - 2)"

printf 'divergence\n'
row conflict "both published changes from the same start" \
	"$(entry B1 S0 3)" "$(st B1)" "$(entry A1 S0 2)"
row conflict "they moved on, and I have unpublished work" \
	"$(entry S0 - 1)" "$(st B1)" "$(entry A1 S0 2)"
row ahead "unpublished work here, and they have not moved" \
	"$(entry A1 A1 2)" "$(st B1)" "$(entry A1 - 2)"

printf 'first contact\n'
row check-ff "neither side has taken anything from the other" \
	"$(entry S0 - 1)" "$(st S0)" "$(entry A1 - 2)"
row check-ff "this machine has never published" \
	null "$(st S0)" "$(entry A1 - 2)"
row apply "stale clean clone behind theirs" \
	null "$(st S0)" "$(entry A1 - 2)" null true false
row ahead "theirs is behind this clean clone" \
	null "$(st A1)" "$(entry S0 - 1)" null false true
row conflict "neither is an ancestor of the other" \
	null "$(st B1)" "$(entry A1 - 2)" null false false

printf 'absent worktrees\n'
row apply "a worktree this machine never had" \
	null null "$(entry A1 - 2)"
row ahead "removed here since publishing it" \
	"$(entry S0 - 1)" null "$(entry S0 - 1)"
row ahead "removal published here after their last change" \
	null null "$(entry A1 - 2026-09-01T00:00:00Z)" '"2026-09-02T00:00:00Z"'
row apply "their change is newer than the removal here" \
	null null "$(entry A1 - 2026-09-03T00:00:00Z)" '"2026-09-02T00:00:00Z"'

done_testing
```

- [ ] **Step 2: Run it and see it fail**

Run: `chmod +x srcsync/.config/srcsync/tests/decide.test.sh && srcsync/.config/srcsync/tests/decide.test.sh`
Expected: `0 passed, 16 failed`

- [ ] **Step 3: Write `lib/decide.jq`**

```jq
# Which way one worktree should move. See DESIGN.md "Apply: the one rule".
#
# Input:
#   mine        this machine's last published entry, or null
#   now         {branch, head, tree} as the worktree is right now, or null if absent
#   theirs      the other machine's entry
#   removed_at  when this machine published the worktree's removal, or null
#   ff_forward  now is clean and its head is an ancestor of theirs, or null if unchecked
#   ff_back     theirs is clean and its head is an ancestor of now's, or null if unchecked
#
# Output, one of:
#   same      the two already match
#   ahead     this side holds everything theirs does; they will take ours
#   apply     take theirs
#   conflict  both moved; the picker decides
#   check-ff  first contact, and the answer needs the two ff flags
#
# base is the other machine's state an entry was built from. It is what tells
# "they moved on from what I have" apart from "we both moved".

def st: {branch, head, tree};
def eq($a; $b): $a != null and $b != null and ($a | st) == ($b | st);

if .now == null then
  if .mine != null then "ahead"
  elif .removed_at != null and .removed_at >= .theirs.changed_at then "ahead"
  else "apply" end
elif eq(.now; .theirs) then "same"
elif eq(.theirs; .mine.base) then "ahead"
elif .mine == null or (.mine.base == null and .theirs.base == null) then
  if .ff_forward == null then "check-ff"
  elif .ff_forward then "apply"
  elif .ff_back then "ahead"
  else "conflict" end
elif eq(.now; .mine) | not then "conflict"
elif eq(.theirs.base; .mine) or eq(.mine; .mine.base) then "apply"
else "conflict" end
```

- [ ] **Step 4: Run the test and see it pass**

Run: `srcsync/.config/srcsync/tests/decide.test.sh`
Expected: `16 passed, 0 failed`

- [ ] **Step 5: Commit, after asking**

```bash
git add srcsync/.config/srcsync/lib/decide.jq srcsync/.config/srcsync/tests/decide.test.sh
git commit -m "Decide which way a srcsync worktree moves

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Publish, routing and the default config

**Files:**
- Create: `srcsync/.config/srcsync/lib/publish.sh`
- Create: `srcsync/.config/srcsync/srcsync.sh`
- Create: `srcsync/.config/srcsync/config`
- Test: `srcsync/.config/srcsync/tests/routing.test.sh`

**Interfaces:**
- Consumes: everything `lib/common.sh` and `lib/snapshot.sh` produce.
- Produces, in `lib/publish.sh`: `find_repos`, `find_worktrees repo_dir`, `hub_update` (clone or pull the hub into `$HUB_DIR`), `hub_publish machine_json_file`, `publish_worktree repo_dir repo_key target wt_dir`, `publish_repo repo_dir` (prints the repo's state-file entry, or nothing when skipped), `push_pending`, `cmd_publish`.
- Produces: the state file at `$LAST`, shaped like DESIGN.md "The state file" plus a `base` field on each worktree (Task 5 documents it).

- [ ] **Step 1: Write the failing test**

`srcsync/.config/srcsync/tests/routing.test.sh`, executable:

```bash
#!/usr/bin/env bash
# Where snapshots go, and what never goes anywhere. Company code reaches only
# the repo's own origin, whatever the config says, because a mistake there puts
# it on a personal account. A push over the size cap is refused. And a run with
# nothing new pushes nothing, since it happens every few minutes.
#
#   ./routing.test.sh

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

machine a
machine b
cat >"$(home a)/.config/srcsync/config" <<'CFG'
company acme
team acme-team
exclude .env
sync src/work hub
CFG

printf 'company repos\n'

git init -q --bare "$GH/acme-fork.git"
github_repo work a src/work
g a src/work remote set-url origin "$GH/acme-fork.git"
g a src/work push -q origin main
echo "wip" >>"$(home a)/src/work/README"
on a publish
assert_eq "" "$(refs_in hub)" "a company repo sends nothing to the hub, despite the override"
assert_eq "refs/srcsync/a/src/work/tree" "$(refs_in acme-fork | cut -d' ' -f2)" \
	"its snapshot goes to its own origin"

git init -q --bare "$GH/acme-team.git"
github_repo shared a src/shared
g a src/shared remote set-url origin "$GH/acme-team.git"
echo "wip" >>"$(home a)/src/shared/README"
on a publish
assert_eq "" "$(refs_in acme-team)" "a company repo whose origin is the team repo is not synced"
assert_eq 1 "$(grep -c 'src/shared origin is the team repo, fork it first' "$WORK/a.log")" \
	"and the reason is reported"
assert_eq "null" "$(jq -c '.repos["src/shared"]' "$(home a)/.local/state/srcsync/last.json")" \
	"and it is left out of the state file"

printf 'what gets pushed\n'

github_repo clean a src/clean
on a publish
assert_eq "null" "$(jq -r '.repos["src/clean"].worktrees["src/clean"].snapshot' \
	"$(home a)/.local/state/srcsync/last.json")" "a clean worktree already on its remote needs no snapshot"
assert_eq "" "$(refs_in hub | grep src/clean)" "so none is pushed"

hub_before=$(git -C "$GH/hub.git" rev-parse main)
refs_before=$(refs_in hub; refs_in acme-fork)
on a publish
assert_eq "$hub_before" "$(git -C "$GH/hub.git" rev-parse main)" "an unchanged run leaves the state file alone"
assert_eq "$refs_before" "$(refs_in hub; refs_in acme-fork)" "and pushes no snapshot"

printf 'size\n'

echo "max_size 20K" >>"$(home a)/.config/srcsync/config"
head -c 100000 /dev/urandom >"$(home a)/src/clean/blob"
on a publish
assert_eq 1 "$(grep -c 'src/clean snapshot is .* over the .* cap; not published' "$WORK/a.log")" \
	"a snapshot over the cap is refused and reported"
blob=$(git hash-object "$(home a)/src/clean/blob")
assert_eq "no" "$(git -C "$GH/hub.git" cat-file -e "$blob" 2>/dev/null && echo yes || echo no)" \
	"and does not reach the hub"

printf 'the lock\n'

mkdir -p "$(home a)/.local/state/srcsync/lock"
sleep 30 &
echo $! >"$(home a)/.local/state/srcsync/lock/pid"
on a publish
assert_eq 1 "$(grep -c 'another run holds the lock' "$WORK/a.log")" "a held lock stops a second run"
kill $!
wait $! 2>/dev/null
on a publish
assert_eq 1 "$(grep -c 'another run holds the lock' "$WORK/a.log")" "a dead holder's lock is taken over"
assert_eq "no" "$([ -e "$(home a)/.local/state/srcsync/lock" ] && echo yes || echo no)" \
	"and released at the end"

done_testing
```

- [ ] **Step 2: Run it and see it fail**

Run: `chmod +x srcsync/.config/srcsync/tests/routing.test.sh && srcsync/.config/srcsync/tests/routing.test.sh`
Expected: `6 passed, 8 failed`. `srcsync.sh` does not exist yet. The six that pass assert an absence, such as no refs in the hub.

- [ ] **Step 3: Write `lib/publish.sh`**

```bash
# Publish: snapshot every worktree that changed, push the snapshots, and
# rewrite this machine's file in the hub. See DESIGN.md "The state file".

# Every repo up to two levels under ~/src.
find_repos() {
	find "$SRCSYNC_SRC" -mindepth 2 -maxdepth 3 -name .git -type d -prune 2>/dev/null |
		sed 's#/\.git$##' | sort
}

# Every live worktree of a repo, main first, as git reports it.
find_worktrees() { # repo_dir
	git -C "$1" worktree list --porcelain | awk '
		/^worktree / { p = substr($0, 10) }
		/^bare$/ || /^prunable/ { p = "" }
		/^$/ { if (p != "") print p; p = "" }
		END { if (p != "") print p }'
}

# The hub clone, up to date with the remote. A hub nobody has pushed to yet has
# no main, and there is nothing to pull.
hub_update() {
	if [ ! -d "$HUB_DIR/.git" ]; then
		git clone -q "$SRCSYNC_HUB" "$HUB_DIR" 2>/dev/null || return 1
	fi
	git -C "$HUB_DIR" ls-remote --exit-code origin refs/heads/main >/dev/null 2>&1 || return 0
	git -C "$HUB_DIR" pull -q --rebase origin main
}

hub_publish() { # machine_json_file
	hub_update || return 1
	mkdir -p "$HUB_DIR/machines"
	cp "$1" "$HUB_DIR/machines/$SRCSYNC_HOST.json"
	git -C "$HUB_DIR" add machines
	if ! git -C "$HUB_DIR" diff --cached --quiet; then
		git -C "$HUB_DIR" commit -q -m "publish $SRCSYNC_HOST" || return 1
	fi
	git -C "$HUB_DIR" push -q origin HEAD:main
}

# One worktree's entry as a line of JSON, or nothing when it cannot be
# published. Changed worktrees get a snapshot and a local ref; the push is left
# to push_pending, once per repo.
publish_worktree() { # repo_dir repo_key target wt
	local repo=$1 rkey=$2 target=$3 wt=$4 wkey st branch head tracking tree prev now_st snap size
	wkey=$(key_of "$wt") || {
		say "$wt is outside \$HOME, skipped"
		return
	}
	git check-ref-format "$(snap_ref "$SRCSYNC_HOST" "$wkey")" || {
		say "$wkey cannot be a ref name, skipped"
		return
	}
	st=$(worktree_state "$wt") || {
		say "$wkey has no commits yet, skipped"
		return
	}
	IFS=$'\t' read -r branch head tracking tree <<<"$st"
	now_st=$(state_json "$branch" "$head" "$tracking" "$tree")
	prev=$(jq -c --arg r "$rkey" --arg w "$wkey" '.repos[$r].worktrees[$w] // null' "$LAST")

	if [ "$prev" != null ] &&
		jq -e --argjson n "$now_st" '{branch, head, tracking, tree} == $n' <<<"$prev" >/dev/null; then
		printf '%s\n' "$prev"
		return
	fi

	snap=null
	if [ "$tree" != "$(git -C "$wt" rev-parse "$head^{tree}")" ] || ! on_remote "$wt" "$head"; then
		snap=$(make_snapshot "$wt" "$wkey" "$tree" "$head" "$branch" "$tracking") || return
		size=$(push_size "$repo" "$snap" "$target")
		if [ "$size" -gt "$CFG_MAX_SIZE" ]; then
			say "$wkey snapshot is $size bytes, over the $CFG_MAX_SIZE byte cap; not published"
			[ "$prev" != null ] && printf '%s\n' "$prev"
			return
		fi
		git -C "$repo" update-ref "$(snap_ref "$SRCSYNC_HOST" "$wkey")" "$snap"
		mark_pending "$rkey"
		snap=\"$snap\"
	fi
	jq -c --argjson s "$snap" --arg at "$(now)" --argjson prev "$prev" \
		'. + {snapshot: $s, changed_at: $at, base: ($prev.base // null)}' <<<"$now_st"
}

# One repo's entry. Worktrees that were in the last publish and are gone now go
# into removed; removals older than 30 days drop out.
publish_repo() { # repo_dir
	local repo=$1 rkey target origin upstream wt wkey line wts="{}" cutoff
	rkey=$(key_of "$repo") || return
	target=$(sync_target "$repo" "$rkey")
	case $target in skip:*)
		say "$rkey ${target#skip:}"
		return
		;;
	esac
	origin=$(git -C "$repo" remote get-url origin 2>/dev/null) || origin=""
	upstream=$(git -C "$repo" remote get-url upstream 2>/dev/null) || upstream=""
	while IFS= read -r wt; do
		wkey=$(key_of "$wt") || continue
		line=$(publish_worktree "$repo" "$rkey" "$target" "$wt")
		[ -n "$line" ] || continue
		wts=$(jq -c --arg w "$wkey" --argjson e "$line" '.[$w] = $e' <<<"$wts")
	done < <(find_worktrees "$repo")
	cutoff=$(date -u -v-30d +%Y-%m-%dT%H:%M:%SZ)
	jq -c --arg r "$rkey" --arg o "$origin" --arg u "$upstream" --arg s "$target" \
		--argjson wts "$wts" --arg at "$(now)" --arg cutoff "$cutoff" '
		(.repos[$r] // {}) as $prev
		| {($r): {
			origin: (if $o == "" then null else $o end),
			upstream: (if $u == "" then null else $u end),
			sync: $s,
			worktrees: $wts,
			removed: (
				(($prev.removed // {}) | with_entries(select(.value >= $cutoff)))
				+ (($prev.worktrees // {}) | keys
					| map(select($wts[.] == null) | {key: ., value: $at}) | from_entries)
				| with_entries(select($wts[.key] == null))
			)
		}}' "$LAST"
}

# Pushes the snapshot refs of every repo with unpushed ones. A repo that fails
# stays pending for the next run.
push_pending() {
	local rkey repo target left=""
	[ -f "$PENDING" ] || return 0
	while IFS= read -r rkey; do
		[ -n "$rkey" ] || continue
		repo=$HOME_P/$rkey
		target=$(sync_target "$repo" "$rkey")
		case $target in skip:*) continue ;; esac
		if ! git -C "$repo" push -q --force --no-verify "$(target_url "$target")" \
			"refs/srcsync/$SRCSYNC_HOST/*:refs/srcsync/$SRCSYNC_HOST/*" 2>/dev/null; then
			say "$rkey: push failed, will retry"
			left=$left$rkey$'\n'
		fi
	done <"$PENDING"
	printf '%s' "$left" >"$PENDING"
	[ -z "$left" ]
}

cmd_publish() {
	local repo add repos="{}" doc ok=0
	ensure_last
	while IFS= read -r repo; do
		add=$(publish_repo "$repo")
		[ -n "$add" ] && repos=$(jq -c --argjson add "$add" '. + $add' <<<"$repos")
	done < <(find_repos)
	push_pending || ok=1

	doc=$SRCSYNC_STATE/publish.json
	jq --arg h "$SRCSYNC_HOST" --arg at "$(now)" --argjson repos "$repos" \
		'{host: $h, published_at: $at, repos: $repos}' "$LAST" >"$doc"
	if ! cmp -s <(jq -S .repos "$LAST") <(jq -S .repos "$doc"); then
		touch "$HUB_PENDING"
	fi
	mv "$doc" "$LAST"

	if [ -f "$HUB_PENDING" ]; then
		if hub_publish "$LAST"; then
			rm -f "$HUB_PENDING"
		else
			say "hub push failed, will retry"
			ok=1
		fi
	fi
	[ $ok = 0 ] && now >"$LAST_SUCCESS"
	return $ok
}
```

- [ ] **Step 4: Write `srcsync.sh` with publish and status**

Task 4 adds apply and sync.

```bash
#!/usr/bin/env bash
# Carries repos, worktrees and uncommitted work between two machines through
# GitHub. DESIGN.md has the why.
#
#   srcsync.sh publish   snapshot what changed here and push it
#   srcsync.sh status    last sync, unpushed repos, conflicts
set -u

LIB=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib
. "$LIB/common.sh"
. "$LIB/snapshot.sh"
. "$LIB/publish.sh"

cmd_status() {
	local at
	at=$(cat "$LAST_SUCCESS" 2>/dev/null) || at=never
	echo "last sync: $at"
	[ -s "$PENDING" ] && echo "unpushed: $(tr '\n' ' ' <"$PENDING")"
	[ -f "$CONFLICTS" ] && jq -r '.[] | "conflict: \(.worktree) (\(.host))"' "$CONFLICTS"
	return 0
}

load_config
case ${1:-} in
publish)
	take_lock || {
		say "another run holds the lock"
		exit 0
	}
	;;
esac
case ${1:-} in
publish) cmd_publish ;;
status) cmd_status ;;
*)
	echo "usage: srcsync.sh publish|status" >&2
	exit 2
	;;
esac
```

Run: `chmod +x srcsync/.config/srcsync/srcsync.sh`

- [ ] **Step 5: Run the test and see it pass**

Run: `srcsync/.config/srcsync/tests/routing.test.sh`
Expected: `14 passed, 0 failed`

- [ ] **Step 6: Write the default `config`**

`upngopay` is the team org: `upngo/slack-hugo` has it as origin today and will be skipped until forked.

```
# srcsync settings. lib/common.sh load_config reads this, one per line.

# A repo with any remote URL containing this is company code. Its snapshots go
# only to its own origin, never the personal hub, whatever a sync line says.
company upngo
# A company repo whose origin contains this is the shared team repo. Snapshot
# refs would land on colleagues' fetches, so it is skipped until forked.
team upngopay

# Never snapshotted, whether or not the repo ignores them.
exclude .env
exclude .env.*
exclude *.pem
exclude *.key
exclude .envrc

max_size 50M

# sync <path from $HOME> hub|origin|skip
```

Check it parses:

Run: `SRCSYNC_CONFIG=srcsync/.config/srcsync/config /bin/bash -c '. srcsync/.config/srcsync/lib/common.sh; load_config; echo "$CFG_MAX_SIZE"; printf %s "$CFG_EXCLUDE"'`
Expected: `52428800`, then the five exclude patterns one per line, and no `unknown keyword` line.

- [ ] **Step 7: Run every test so far**

Run: `for t in srcsync/.config/srcsync/tests/*.test.sh; do $t | tail -1; done`
Expected: three lines, each ending `0 failed`.

- [ ] **Step 8: Commit, after asking**

```bash
git add srcsync/.config/srcsync/lib/publish.sh srcsync/.config/srcsync/srcsync.sh \
	srcsync/.config/srcsync/config srcsync/.config/srcsync/tests/routing.test.sh
git commit -m "Publish srcsync snapshots, keeping company code off the hub

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Apply

**Files:**
- Create: `srcsync/.config/srcsync/lib/apply.sh`
- Modify: `srcsync/.config/srcsync/srcsync.sh` (replace it whole, Step 6)
- Test: `srcsync/.config/srcsync/tests/handoff.test.sh`
- Test: `srcsync/.config/srcsync/tests/worktrees.test.sh`
- Test: `srcsync/.config/srcsync/tests/conflict.test.sh`

**Interfaces:**
- Consumes: `lib/decide.jq` and its input shape from Task 2. `sync_target`, `target_url`, `snap_ref`, `mark_pending`, `ensure_last`, `hub_update` and the state file from Tasks 1 and 3.
- Produces, in `lib/apply.sh`: `claude_busy dir`, `now_json wt`, `set_mine repo_key wt_key entry`, `record_theirs repo_dir repo_key wt_key theirs`, `clone_repo dir origin upstream`, `fetch_theirs repo_dir sync host theirs`, `ff_flags wt now theirs` (prints `true|false true|false`), `lay_tree wt tree head`, `apply_worktree repo_dir wt theirs`, `decide mine now theirs removed_at ff_forward ff_back`, `apply_one host repo_key repo_json wt_key`, `apply_removal host repo_key wt_key removed_at`, `cmd_apply`.
- Produces: `$CONFLICTS`, a JSON array of `{repo, worktree, host, mine, theirs}`, rewritten by every apply.

- [ ] **Step 1: Write the handoff test**

`srcsync/.config/srcsync/tests/handoff.test.sh`, executable:

```bash
#!/usr/bin/env bash
# The walk-away handoff, both ways. A works on an unpushed branch, with a local
# commit, an edit, a new file and a deletion, then walks away. B must come up
# with the same branch, the same HEAD and the same uncommitted changes, with
# the index left alone so nothing looks staged. Then B works and hands back.
# An excluded file such as .env stays where it was written, in both directions.
#
#   ./handoff.test.sh

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

machine a
machine b
github_repo app a src/app
git clone -q "$GH/app.git" "$(home b)/src/app" 2>/dev/null

printf 'handoff a to b\n'

g a src/app switch -q -c feature
echo "local commit" >"$(home a)/src/app/committed"
g a src/app add committed
g a src/app commit -q -m "not pushed"
echo "edited" >>"$(home a)/src/app/README"
echo "new" >"$(home a)/src/app/untracked"
rm "$(home a)/src/app/committed"

on a publish
on b publish
on b apply

assert_eq "feature" "$(g b src/app branch --show-current)" "b is on a's branch"
assert_eq "$(g a src/app rev-parse HEAD)" "$(g b src/app rev-parse HEAD)" \
	"b's HEAD is a's unpushed commit"
assert_eq "$(changes a src/app)" "$(changes b src/app)" \
	"b has a's edit, new file and deletion"
assert_eq "" "$(g b src/app diff --cached --name-only)" "nothing is staged on b"
assert_eq "hello
edited" "$(cat "$(home b)/src/app/README")" "the edit's content arrived"

printf 'handoff b back to a\n'

on b publish
echo "from b" >"$(home b)/src/app/second"
on b publish
on a publish
on a apply
assert_eq "$(changes b src/app)" "$(changes a src/app)" "a has b's new file on top"
assert_eq "from b" "$(cat "$(home a)/src/app/second" 2>/dev/null)" "with b's content"

printf 'a round trip settles\n'

on a publish
on b apply
assert_eq 1 "$(grep -c "took a's state" "$WORK/b.log")" \
	"b took a's state once, and nothing from the round trip"
assert_eq "[]" "$(jq -c . "$(home b)/.local/state/srcsync/conflicts.json")" \
	"no conflict after a clean handoff"

printf 'secrets stay home\n'

echo "exclude .env" >"$(home a)/.config/srcsync/config"
echo "exclude .env" >"$(home b)/.config/srcsync/config"
echo "SECRET=a" >"$(home a)/src/app/.env"
echo "change" >>"$(home a)/src/app/README"
on a publish
on b apply
assert_eq "no" "$([ -e "$(home b)/src/app/.env" ] && echo yes || echo no)" \
	"an excluded file does not travel"
echo "SECRET=b" >"$(home b)/src/app/.env"
on b publish
echo "more" >>"$(home a)/src/app/README"
on a publish
on b apply
assert_eq "SECRET=b" "$(cat "$(home b)/src/app/.env" 2>/dev/null)" \
	"and an apply leaves the other machine's own copy alone"

done_testing
```

- [ ] **Step 2: Write the worktrees test**

`srcsync/.config/srcsync/tests/worktrees.test.sh`, executable:

```bash
#!/usr/bin/env bash
# Worktrees and repos come and go on one machine, and the other follows: a new
# linked worktree appears at the same path, a removed one disappears, and a new
# repo is cloned, or built from the hub when it has no remote at all. A repo's
# main worktree is never removed, since that would be deleting the repo.
#
#   ./worktrees.test.sh

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

machine a
machine b
github_repo app a src/app
on a publish
on b apply

printf 'a new linked worktree\n'

g a src/app worktree add -q -b spike "$(home a)/src/app-spike"
echo "wip" >"$(home a)/src/app-spike/wip"
on a publish
on b apply
assert_eq "spike" "$(g b src/app-spike branch --show-current 2>/dev/null)" \
	"it appears on b, on its branch"
assert_eq "wip" "$(cat "$(home b)/src/app-spike/wip" 2>/dev/null)" "with its uncommitted file"
assert_eq "$(home b)/src/app-spike" \
	"$(g b src/app worktree list --porcelain | awk '/^worktree .*spike/ { print $2 }')" \
	"as a worktree of b's repo, not a copy"

printf 'a removed linked worktree\n'

on b publish
g a src/app worktree remove --force "$(home a)/src/app-spike"
on a publish
on b apply
assert_eq "no" "$([ -e "$(home b)/src/app-spike" ] && echo yes || echo no)" "it disappears from b"
assert_eq "spike" "$(g b src/app branch --list spike --format='%(refname:short)')" \
	"its branch stays for worktree-remove.sh to judge"

printf 'a removed linked worktree that b changed\n'

g a src/app worktree add -q -b keep "$(home a)/src/app-keep"
on a publish
on b apply
on b publish
echo "b's work" >"$(home b)/src/app-keep/mine"
g a src/app worktree remove --force "$(home a)/src/app-keep"
on a publish
on b apply
assert_eq "b's work" "$(cat "$(home b)/src/app-keep/mine" 2>/dev/null)" "it stays on b"

printf 'new repos\n'

github_repo lib a src/lib
git init -q "$(home a)/src/notes"
echo "private" >"$(home a)/src/notes/todo"
g a src/notes add todo
g a src/notes commit -q -m "notes"
on a publish
on b apply
assert_eq "$GH/lib.git" "$(g b src/lib remote get-url origin 2>/dev/null)" \
	"a repo with a remote is cloned from it"
assert_eq "private" "$(cat "$(home b)/src/notes/todo" 2>/dev/null)" \
	"a repo with no remote is built from the hub"
assert_eq "$(g a src/notes rev-parse HEAD)" "$(g b src/notes rev-parse HEAD 2>/dev/null)" \
	"with its history"

printf 'a removed repo\n'

rm -rf "$(home a)/src/lib"
on a publish
on b apply
assert_eq "yes" "$([ -d "$(home b)/src/lib/.git" ] && echo yes || echo no)" \
	"a repo deleted on a is not deleted on b"

done_testing
```

- [ ] **Step 3: Write the conflict test**

`srcsync/.config/srcsync/tests/conflict.test.sh`, executable:

```bash
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
```

- [ ] **Step 4: Run them and see them fail**

Run: `cd srcsync/.config/srcsync/tests && chmod +x handoff.test.sh worktrees.test.sh conflict.test.sh && for t in handoff worktrees conflict; do ./$t.test.sh | tail -1; done; cd -`
Expected:
```
3 passed, 8 failed
1 passed, 9 failed
1 passed, 8 failed
```
`srcsync.sh` has no `apply` yet, so it prints its usage and changes nothing.

- [ ] **Step 5: Write `lib/apply.sh`**

```bash
# Apply: bring each worktree to the other machine's state when lib/decide.jq
# says to. See DESIGN.md "Apply: the one rule".

DECIDE=$LIB/decide.jq

# A Claude mid-turn, or parked on a question, in or under $1. A session file
# whose process is gone does not count: a crash leaves one behind.
claude_busy() { # dir
	local f pid
	for f in "$CC_SESSIONS_DIR"/*.json; do
		[ -f "$f" ] || continue
		pid=$(jq -r --arg p "$1" '
			select((.status == "busy" or .status == "waiting")
				and (.cwd == $p or (.cwd | startswith($p + "/")))) | .pid' "$f" 2>/dev/null)
		[ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && return 0
	done
	return 1
}

# The worktree's state as JSON, or null when it is absent or has no commits.
now_json() { # wt
	local st b h t tr
	[ -e "$1/.git" ] && st=$(worktree_state "$1") || {
		echo null
		return
	}
	IFS=$'\t' read -r b h t tr <<<"$st"
	state_json "$b" "$h" "$t" "$tr"
}

# Replaces this machine's entry for one worktree in last.json, and has the next
# publish push the state file even if nothing else changed.
set_mine() { # repo_key wt_key entry_json
	jq --arg r "$1" --arg w "$2" --argjson e "$3" '.repos[$r].worktrees[$w] = $e' \
		"$LAST" >"$LAST.tmp" && mv "$LAST.tmp" "$LAST"
	touch "$HUB_PENDING"
}

# Records theirs as this machine's state, as though this machine had published
# it: the same entry, based on theirs, with the snapshot under this host's own
# ref so every entry names a commit its own host has pushed.
record_theirs() { # repo_dir repo_key wt_key theirs_json
	local snap
	set_mine "$2" "$3" "$(jq -c \
		'{branch, head, tracking, tree, snapshot, changed_at, base: {branch, head, tree}}' <<<"$4")"
	snap=$(jq -r .snapshot <<<"$4")
	if [ "$snap" != null ]; then
		git -C "$1" update-ref "$(snap_ref "$SRCSYNC_HOST" "$3")" "$snap"
		mark_pending "$2"
	fi
}

# Recreates a repo this machine lacks, at the same path. One that only ever
# lived in the hub starts empty; the snapshot fetch brings its history.
clone_repo() { # dir origin upstream
	if [ "$2" != null ]; then
		git clone -q "$2" "$1" || return 1
	else
		git init -q "$1" || return 1
	fi
	[ "$3" = null ] || git -C "$1" remote add upstream "$3"
}

# Makes the commits theirs names present in the repo: the snapshot ref when
# there is one, or else the head, from whichever remote has it.
fetch_theirs() { # repo_dir sync host theirs_json
	local ref snap head
	snap=$(jq -r .snapshot <<<"$4")
	head=$(jq -r .head <<<"$4")
	if [ "$snap" != null ]; then
		ref=$(snap_ref "$3" "$(jq -r .key <<<"$4")")
		git -C "$1" fetch -q --no-tags "$(target_url "$2")" "+$ref:$ref" 2>/dev/null || return 1
		# The ref is pushed before the state file, so the two can disagree
		# for a run. The next one sees them match.
		[ "$(git -C "$1" rev-parse -q --verify "$ref")" = "$snap" ]
	else
		git -C "$1" cat-file -e "$head^{commit}" 2>/dev/null && return 0
		git -C "$1" fetch -q --all --no-tags 2>/dev/null
		git -C "$1" cat-file -e "$head^{commit}" 2>/dev/null
	fi
}

# Two JSON booleans: now is clean and its head an ancestor of theirs; theirs is
# clean and its head an ancestor of now's.
ff_flags() { # wt now_json theirs_json
	local nh nt th tt fwd=false back=false
	nh=$(jq -r .head <<<"$2") nt=$(jq -r .tree <<<"$2")
	th=$(jq -r .head <<<"$3") tt=$(jq -r .tree <<<"$3")
	[ "$nt" = "$(git -C "$1" rev-parse "$nh^{tree}")" ] &&
		git -C "$1" merge-base --is-ancestor "$nh" "$th" && fwd=true
	[ "$tt" = "$(git -C "$1" rev-parse "$th^{tree}")" ] &&
		git -C "$1" merge-base --is-ancestor "$th" "$nh" && back=true
	echo "$fwd $back"
}

# Writes tree $2 into a worktree that checkout has just set to commit $3, as
# uncommitted changes. Only files that differ are written, so an unchanged file
# keeps its mtime. Untracked files the tree lacks are cleaned, files it deletes
# are removed, and ignored and excluded files are left alone.
lay_tree() { # wt tree head
	local tmp ex=() p
	tmp=$(mktemp "${TMPDIR:-/tmp}/srcsync-index.XXXXXX")
	rm -f "$tmp"
	while IFS= read -r p; do [ -n "$p" ] && ex+=(-e "$p"); done <<EOF
$CFG_EXCLUDE
EOF
	(
		cd "$1" || exit 1
		git clean -fdq ${ex[@]+"${ex[@]}"}
		GIT_INDEX_FILE=$tmp git read-tree "$2" || exit 1
		git diff -z --name-only --no-renames --diff-filter=ACMT "$3" "$2" |
			GIT_INDEX_FILE=$tmp git checkout-index -f -q -z --stdin || exit 1
		git diff -z --name-only --no-renames --diff-filter=D "$3" "$2" | xargs -0 rm -f --
	)
	local rc=$?
	rm -f "$tmp"
	return $rc
}

# Moves the worktree at $2 onto theirs: creates it or switches it, lays the
# snapshot over it, and sets the tracking ref. A branch checked out in another
# worktree fails here rather than being taken from it.
apply_worktree() { # repo_dir wt theirs_json
	local repo=$1 wt=$2 branch head tree tracking
	branch=$(jq -r .branch <<<"$3") head=$(jq -r .head <<<"$3")
	tree=$(jq -r .tree <<<"$3") tracking=$(jq -r .tracking <<<"$3")

	if [ ! -e "$wt/.git" ]; then
		git -C "$repo" worktree prune
		if [ "$branch" = null ]; then
			git -C "$repo" worktree add -q --detach "$wt" "$head" || return 1
		else
			git -C "$repo" worktree add -q -B "$branch" "$wt" "$head" || return 1
		fi
	elif [ "$branch" = null ]; then
		git -C "$wt" checkout -q -f --detach "$head" || return 1
	else
		git -C "$wt" checkout -q -f -B "$branch" "$head" || return 1
	fi
	lay_tree "$wt" "$tree" "$head" || return 1

	if [ "$tracking" != null ] && [ "$branch" != null ]; then
		git -C "$wt" rev-parse -q --verify "refs/remotes/$tracking" >/dev/null ||
			git -C "$wt" fetch -q "${tracking%%/*}" 2>/dev/null
		git -C "$wt" branch -q --set-upstream-to="$tracking" "$branch" 2>/dev/null ||
			say "$(key_of "$wt"): could not track $tracking"
	fi
}

decide() { # mine now theirs removed_at ff_forward ff_back
	jq -cn --argjson mine "$1" --argjson now "$2" --argjson theirs "$3" \
		--argjson removed_at "$4" --argjson ff_forward "$5" --argjson ff_back "$6" \
		'{$mine, $now, $theirs, $removed_at, $ff_forward, $ff_back}' | jq -r -f "$DECIDE"
}

# One worktree of one repo from the other machine.
apply_one() { # host repo_key repo_json wt_key
	local host=$1 rkey=$2 rjson=$3 wkey=$4 repo wt theirs mine now removed sync decision fwd back
	repo=$HOME_P/$rkey wt=$HOME_P/$wkey
	theirs=$(jq -c --arg w "$wkey" '.worktrees[$w] + {key: $w}' <<<"$rjson")
	sync=$(jq -r .sync <<<"$rjson")
	mine=$(jq -c --arg r "$rkey" --arg w "$wkey" '.repos[$r].worktrees[$w] // null' "$LAST")
	removed=$(jq -c --arg r "$rkey" --arg w "$wkey" '.repos[$r].removed[$w] // null' "$LAST")
	now=$(now_json "$wt")

	decision=$(decide "$mine" "$now" "$theirs" "$removed" null null)
	if [ "$decision" = check-ff ]; then
		fetch_theirs "$repo" "$sync" "$host" "$theirs" || {
			say "$wkey: cannot fetch $host's state yet"
			return
		}
		read -r fwd back < <(ff_flags "$wt" "$now" "$theirs")
		decision=$(decide "$mine" "$now" "$theirs" "$removed" "$fwd" "$back")
	fi

	case $decision in
	same)
		if [ "$mine" = null ]; then
			fetch_theirs "$repo" "$sync" "$host" "$theirs" &&
				record_theirs "$repo" "$rkey" "$wkey" "$theirs"
		elif ! jq -e --argjson t "$theirs" '.base == ($t | {branch, head, tree})' <<<"$mine" >/dev/null; then
			set_mine "$rkey" "$wkey" "$(jq -c --argjson t "$theirs" \
				'.base = ($t | {branch, head, tree})' <<<"$mine")"
		fi
		;;
	conflict)
		say "$wkey: changed here and on $host; left alone"
		jq -cn --arg r "$rkey" --arg w "$wkey" --arg h "$host" --argjson mine "$now" \
			--argjson theirs "$theirs" '{repo: $r, worktree: $w, host: $h, mine: $mine, theirs: $theirs}' \
			>>"$CONFLICTS.tmp"
		;;
	apply)
		if claude_busy "$wt"; then
			say "$wkey: Claude is working there; next run"
			return
		fi
		if [ ! -d "$repo" ]; then
			clone_repo "$repo" "$(jq -r .origin <<<"$rjson")" "$(jq -r .upstream <<<"$rjson")" || {
				say "$rkey: clone failed"
				return
			}
		fi
		fetch_theirs "$repo" "$sync" "$host" "$theirs" || {
			say "$wkey: cannot fetch $host's state yet"
			return
		}
		apply_worktree "$repo" "$wt" "$theirs" || {
			say "$wkey: apply failed"
			return
		}
		[ "$(jq -r .tree <<<"$(now_json "$wt")")" = "$(jq -r .tree <<<"$theirs")" ] ||
			say "$wkey: applied, but the result differs from $host's tree"
		record_theirs "$repo" "$rkey" "$wkey" "$theirs"
		say "$wkey: took $host's state"
		;;
	esac
}

# The other machine removed a linked worktree. Follow if the removal is no
# older than this machine's last change to it, nothing changed here since this
# machine published it, and no Claude is working there. A main worktree is a
# whole repo and is never deleted.
apply_removal() { # host repo_key wt_key removed_at
	local repo=$HOME_P/$2 wt=$HOME_P/$3 mine
	[ -f "$wt/.git" ] || return 0
	mine=$(jq -c --arg r "$2" --arg w "$3" '.repos[$r].worktrees[$w] // null' "$LAST")
	[ "$mine" != null ] || return 0
	[[ $4 < $(jq -r .changed_at <<<"$mine") ]] && return 0
	if ! jq -e --argjson n "$(now_json "$wt")" '{branch, head, tracking, tree} == $n' <<<"$mine" >/dev/null; then
		say "$3: removed on $1 but changed here; kept"
		return 0
	fi
	if claude_busy "$wt"; then
		say "$3: Claude is working there; next run"
		return 0
	fi
	git -C "$repo" worktree remove --force "$wt" && say "$3: removed, as on $1"
}

cmd_apply() {
	local f host rkey rjson wkey at
	ensure_last
	hub_update || {
		say "cannot reach the hub"
		return 1
	}
	: >"$CONFLICTS.tmp"
	for f in "$HUB_DIR"/machines/*.json; do
		[ -f "$f" ] || continue
		host=$(jq -r .host "$f")
		[ "$host" = "$SRCSYNC_HOST" ] && continue
		while IFS= read -r rkey; do
			rjson=$(jq -c --arg r "$rkey" '.repos[$r]' "$f")
			while IFS= read -r wkey; do
				apply_one "$host" "$rkey" "$rjson" "$wkey"
			done < <(jq -r '.worktrees | keys_unsorted[]' <<<"$rjson")
			while IFS=$'\t' read -r wkey at; do
				apply_removal "$host" "$rkey" "$wkey" "$at"
			done < <(jq -r '.removed // {} | to_entries[] | "\(.key)\t\(.value)"' <<<"$rjson")
		done < <(jq -r '.repos | keys_unsorted[]' "$f")
	done
	jq -s . "$CONFLICTS.tmp" >"$CONFLICTS" && rm -f "$CONFLICTS.tmp"
}
```

- [ ] **Step 6: Replace `srcsync.sh` with the full version**

```bash
#!/usr/bin/env bash
# Carries repos, worktrees and uncommitted work between two machines through
# GitHub. DESIGN.md has the why.
#
#   srcsync.sh publish   snapshot what changed here and push it
#   srcsync.sh apply     take what changed on the other machine
#   srcsync.sh sync      publish, then apply
#   srcsync.sh status    last sync, unpushed repos, conflicts
set -u

LIB=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib
. "$LIB/common.sh"
. "$LIB/snapshot.sh"
. "$LIB/publish.sh"
. "$LIB/apply.sh"

cmd_status() {
	local at
	at=$(cat "$LAST_SUCCESS" 2>/dev/null) || at=never
	echo "last sync: $at"
	[ -s "$PENDING" ] && echo "unpushed: $(tr '\n' ' ' <"$PENDING")"
	[ -f "$CONFLICTS" ] && jq -r '.[] | "conflict: \(.worktree) (\(.host))"' "$CONFLICTS"
	return 0
}

load_config
case ${1:-} in
publish | apply | sync)
	take_lock || {
		say "another run holds the lock"
		exit 0
	}
	;;
esac
case ${1:-} in
publish) cmd_publish ;;
apply) cmd_apply ;;
sync)
	cmd_publish
	cmd_apply
	;;
status) cmd_status ;;
*)
	echo "usage: srcsync.sh publish|apply|sync|status" >&2
	exit 2
	;;
esac
```

- [ ] **Step 7: Run the tests and see them pass**

Run: `cd srcsync/.config/srcsync/tests && for t in handoff worktrees conflict; do ./$t.test.sh | tail -1; done; cd -`
Expected:
```
11 passed, 0 failed
10 passed, 0 failed
9 passed, 0 failed
```

- [ ] **Step 8: Commit, after asking**

```bash
git add srcsync/.config/srcsync/lib/apply.sh srcsync/.config/srcsync/srcsync.sh \
	srcsync/.config/srcsync/tests/handoff.test.sh srcsync/.config/srcsync/tests/worktrees.test.sh \
	srcsync/.config/srcsync/tests/conflict.test.sh
git commit -m "Apply the other machine's srcsync state when this one is untouched

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Bring DESIGN.md in line, stow, full run

Building the engine showed eleven places where DESIGN.md is wrong or silent. The worst is the apply rule. "Newer `changed_at` wins" would let two machines that both changed a worktree overwrite one side without a word, which is exactly the loss the tool exists to prevent. Fix the spec so the next plan argues from what the code does.

**Files:**
- Modify: `srcsync/.config/srcsync/DESIGN.md`

- [ ] **Step 1: Add `base` to the state file**

In the JSON under "## The state file", after the `"changed_at"` line of the worktree entry, add a comma to that line and then:

```
          "base": { "branch": "feature-x", "head": "<sha>", "tree": "<sha>" }
```

Replace the bullet that begins "`changed_at` is when this machine last saw" with:

```markdown
- `changed_at` is when this machine last saw the worktree differ from its
  previous publish. It only settles removals, which have no state to compare.
- `base` is the other machine's state this entry was built from. An apply sets
  it, and it rides along until this machine changes the worktree again. It is
  `null` for work that started here.
- `snapshot` is `null` for a clean worktree whose HEAD is already on a remote.
  The other machine fetches HEAD from origin instead, and a clone of a large
  project does not get its history pushed to the hub.
```

Under the JSON, after "Entries older than 30 days are dropped.", add:

```markdown
The file is pushed to the hub only when a repo entry changed, or when the last
push of it failed. A run with nothing new pushes nothing.
```

- [ ] **Step 2: Add skip routing and the push-size rule to "Where snapshots go"**

After the `hub` bullet, add:

```markdown
- `skip`, from a `sync <path> skip` config line, for a repo that should not
  sync at all.
```

Replace the last paragraph of the section, the one beginning "A company repo whose `origin` is the team repo", with:

```markdown
A company repo whose `origin` is the team repo itself, not a fork, is skipped
and reported until it has a fork. Otherwise the snapshot refs are visible to
anyone listing the team repo's refs. A `team` config pattern names the team
repo. `upngo/slack-hugo` is one today.

The size cap measures what the push would send, not the tree:
`git rev-list --objects --disk-usage <snapshot> --not` every srcsync ref, plus
the remote-tracking refs when the target is origin. A few edits in a big clone
cost kilobytes.
```

- [ ] **Step 3: Replace the rule in "Apply: the one rule"**

Replace the first two paragraphs, from "For each worktree, compare" through "There's no prompt.", with:

```markdown
For each worktree, compare three states: the other machine's entry (theirs),
this machine's last publish (mine), and the worktree as it is now.
`lib/decide.jq` holds the rule, and `tests/decide.test.sh` is its table.

- Now matches theirs: nothing to do.
- Theirs matches mine's `base`: they have not moved since this machine took
  their state. Keep this one.
- Now differs from mine, and theirs moved: both sides changed it. Conflict.
- Theirs was built on mine, or mine is only what this machine took from them:
  apply. There's no prompt.
- Anything else: conflict.

Comparing `changed_at` cannot tell "they moved on from what I have" from "we
both moved", and in the second case the newer timestamp would overwrite the
other side's work. `base` is what tells them apart.

When neither entry has a `base`, as on first contact or before this machine has
ever published, git decides. If this worktree is clean at a commit that theirs
descends from, apply. If theirs is clean at a commit this one descends from,
keep this one. Otherwise, conflict.
```

Replace step 7 of "Applying a worktree" with:

```markdown
7. Record the result as this machine's state, with theirs as its `base`, so it
   counts as untouched. A snapshot is re-pointed under this machine's own ref
   and pushed, so the hub holds it under both hosts.
```

Replace the paragraph after the steps, beginning "A removal the other side published", with:

```markdown
A removal the other side published at or after this machine's `changed_at`
removes the worktree here too, if it is untouched. A tie goes to the removal;
the touched check is what protects work here. Only linked worktrees are ever
removed, never a main worktree or a repo. The branch is left for
`worktree-remove.sh` to judge.
```

- [ ] **Step 4: Widen check 3**

Replace check 3 under "## Check before building" with:

```markdown
3. Do GitHub and Bitbucket accept pushes to `refs/srcsync/*` on a fork, and
   keep them? `upngo/ordering-html` is on Bitbucket.
```

- [ ] **Step 5: Add to the test list**

Under "## Tests", after "The exclude list and size cap hold.", add:

```markdown
- A worktree removed on A but changed on B is kept on B.
- A repo deleted on A is not deleted on B.
- One run at a time: a held lock stops a second run, and a dead holder's lock
  is taken over.
```

- [ ] **Step 6: Scan the edits for the writing rules**

Run: `grep -n '—' srcsync/.config/srcsync/DESIGN.md`
Expected: no output.

- [ ] **Step 7: Stow and run the whole suite from the stowed path**

`~/.config/srcsync` does not exist yet, so stow folds it into one symlink.

Run: `stow -v -t ~/ -S srcsync && ls -l ~/.config/srcsync && for t in ~/.config/srcsync/tests/*.test.sh; do printf '%s: ' "${t##*/}"; $t | tail -1; done`
Expected: `~/.config/srcsync` is a symlink ending in `dotfiles/srcsync/.config/srcsync`, then six lines each ending `0 failed`.

- [ ] **Step 8: Dry-run status on this machine**

Run: `~/.config/srcsync/srcsync.sh status`
Expected: `last sync: never` and nothing else. No publish runs here yet: the hub does not exist until Task 6.

- [ ] **Step 9: Commit, after asking**

```bash
git add srcsync/.config/srcsync/DESIGN.md
git commit -m "Correct the srcsync apply rule and routing in DESIGN.md

Newer changed_at would overwrite work when both machines changed a
worktree. A base field records what each side took from the other.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Check 3, then bootstrap

These touch GitHub, Bitbucket and a company fork. The user runs or approves each step. Nothing here is automated.

- [ ] **Step 1: Check 3 on GitHub**

In any company fork on company GitHub, push a throwaway ref and read it back:

```bash
git push origin HEAD:refs/srcsync/check/probe
git ls-remote origin 'refs/srcsync/*'
git push origin :refs/srcsync/check/probe
```

Expected: `ls-remote` lists the probe. If the push is refused, `origin` routing cannot work for company repos and DESIGN.md needs a new answer before going further.

- [ ] **Step 2: Check 3 on Bitbucket**

Same three commands in `~/src/upngo/ordering-html`, whose origin is Bitbucket.

- [ ] **Step 3: Create the hub**

Create `BatsShadow/srcsync-state` on GitHub, private and empty. `hub_update` handles a hub with no `main` yet.

- [ ] **Step 4: Fork slack-hugo**

Fork `upngo/slack-hugo` from the team org to the personal company account, then point the local clone's `origin` at the fork and add the team repo as `upstream`. Until then the first publish reports it as skipped, which is correct.

- [ ] **Step 5: First publish on the main machine**

Run: `~/.config/srcsync/srcsync.sh publish; ~/.config/srcsync/srcsync.sh status`
Check: `~/.local/state/srcsync/last.json` lists the repos under `~/src`. Company repos show `"sync": "origin"`. Nothing matching `upngo` appears under `refs/srcsync` in the hub (`git ls-remote git@github.com-batsshadow:BatsShadow/srcsync-state.git 'refs/srcsync/*' | grep -c upngo` prints `0`). Any "over the cap" line names a repo to exclude or skip.

- [ ] **Step 6: Second machine**

Stow, then `srcsync.sh apply`, then compare `git status` and `git log -1` in a few worktrees on both machines.

- [ ] **Step 7: The acceptance test**

Walk away from the main machine mid-task, run `srcsync.sh publish` there first (triggers are the next plan), and pick the work up on the other machine with `srcsync.sh apply`.
