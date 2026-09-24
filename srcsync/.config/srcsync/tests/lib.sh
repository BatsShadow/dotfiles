# Two machines side by side for the srcsync tests. Each machine is a $HOME with
# its own ~/src, state and Claude sessions dir, and GitHub is a directory of
# bare repos. Clones name it by a github.com URL, $GHURL/<name>.git, which the
# test gitconfig rewrites to the directory, since srcsync ignores a repo whose
# origin is not on GitHub. Real git throughout: what srcsync rests on are facts about git,
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
GHURL=git@github.com:me
git config --global url."$GH/".insteadOf "$GHURL/"

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

# Makes machine $1's config own the test repos, so they sync as they did
# before owner lines existed. Every runner calls it, since tests rewrite the
# config whole. A config that names its own owner keeps it.
own() { # machine
	local c=$WORK/$1/.config/srcsync/config
	grep -qs '^owner ' "$c" || echo "owner me" >>"$c"
}

# Runs srcsync as machine $1. stderr, where srcsync reports, goes to
# $WORK/<machine>.log so a test can check what it said.
on() { # machine command
	local m=$1
	shift
	own "$m"
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
	git clone -q "$GHURL/$1.git" "$WORK/$2/$3" 2>/dev/null
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
	own "$m"
	HOME=$WORK/$m SRCSYNC_HOST=$m SRCSYNC_HUB=$GH/hub.git LIB=$TESTS/../lib /bin/bash -c '
		set -u
		. "$LIB/common.sh"; . "$LIB/snapshot.sh"; . "$LIB/publish.sh"; . "$LIB/apply.sh"; . "$LIB/transcripts.sh"; . "$LIB/restart.sh"
		load_config
		"$@"' _ "$@"
}
