# Shared by every srcsync command: where things live, the config, the lock, and
# which remote a repo's snapshots may go to.
#
# Everything hangs off $HOME so the tests can stand two machines side by side
# as two directories. Written for /bin/bash 3.2, because launchd runs agents
# with a PATH that finds that one and not Homebrew's: no associative arrays, no
# mapfile, and every possibly-empty array expanded as ${a[@]+"${a[@]}"}, which
# 3.2 otherwise reports as unbound under set -u.

SRCSYNC_HUB=${SRCSYNC_HUB:-git@github.com-batsshadow:BatsShadow/srcsync-state.git}
SRCSYNC_CONFIG=${SRCSYNC_CONFIG:-$HOME/.config/srcsync/config}
SRCSYNC_STATE=${SRCSYNC_STATE:-$HOME/.local/state/srcsync}

# This machine's name on the hub and in its refs, resolved on the first run
# and read back after. hostname -s follows DHCP and Bonjour, and a machine
# that changed name took its own old file for the other machine's and rolled
# its worktrees back every run.
host_id() {
	local f=$SRCSYNC_STATE/host id
	id=$(cat "$f" 2>/dev/null)
	# a machine that published before the id was kept keeps its name
	[ -n "$id" ] || id=$(jq -r '.host // empty' "$SRCSYNC_STATE/last.json" 2>/dev/null)
	if [ -z "$id" ]; then
		id=$(scutil --get LocalHostName 2>/dev/null) || id=
		[ -n "$id" ] || id=$(hostname -s)
	fi
	[ -f "$f" ] || { mkdir -p "$SRCSYNC_STATE" && echo "$id" >"$f"; }
	echo "$id"
}
SRCSYNC_HOST=${SRCSYNC_HOST:-$(host_id)}
SRCSYNC_SRC=${SRCSYNC_SRC:-$HOME/src}
CC_SESSIONS_DIR=${CC_SESSIONS_DIR:-$HOME/.claude/sessions}
CC_PROJECTS_DIR=${CC_PROJECTS_DIR:-$HOME/.claude/projects}

# git status refreshes a stale index and writes it back. That write moved the
# index mtime publish orders worktrees by, and could take the user's lock.
export GIT_OPTIONAL_LOCKS=0

# git reports physical paths, so keys are cut from the physical $HOME. On a
# Mac /Users/scott has no symlink in it; the tests' temp dirs under /var do.
HOME_P=$(cd "$HOME" && pwd -P)

LAST=$SRCSYNC_STATE/last.json
HUB_DIR=$SRCSYNC_STATE/hub
PENDING=$SRCSYNC_STATE/pending
HUB_PENDING=$SRCSYNC_STATE/hub-pending
CONFLICTS=$SRCSYNC_STATE/conflicts.json
LAST_SUCCESS=$SRCSYNC_STATE/last-success
# only a full publish writes it: the checkpoint's cutoff
LAST_FULL=$SRCSYNC_STATE/last-full

say() { printf 'srcsync: %s\n' "$*" >&2; }

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

CFG_COMPANY=""
CFG_TEAM=""
CFG_FORGE=""
CFG_OWNER=""
CFG_EXCLUDE=""
CFG_OVERRIDES=""
CFG_MAX_SIZE=$((50 * 1048576))
CFG_AUTO=off
CFG_TRANSCRIPTS=off

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
#   forge    <host a tracked origin is on>, github.com if none
#   owner    <an account whose repos are always tracked>
#   exclude  <gitignore-style name>
#   max_size <bytes, or with K, M or G>
#   auto     on|off
#   transcripts on|off
#   sync     <path from $HOME> hub|origin|skip
load_config() {
	local kw a b nl=$'\n'
	[ -f "$SRCSYNC_CONFIG" ] || return 0
	while read -r kw a b; do
		case $kw in
		'' | \#*) ;;
		company) CFG_COMPANY=$CFG_COMPANY$a$nl ;;
		team) CFG_TEAM=$CFG_TEAM$a$nl ;;
		forge) CFG_FORGE=$CFG_FORGE$a$nl ;;
		owner) CFG_OWNER=$CFG_OWNER$a$nl ;;
		exclude) CFG_EXCLUDE=$CFG_EXCLUDE$a$nl ;;
		max_size) CFG_MAX_SIZE=$(to_bytes "$a") ;;
		auto) CFG_AUTO=$a ;;
		transcripts) CFG_TRANSCRIPTS=$a ;;
		sync) CFG_OVERRIDES=$CFG_OVERRIDES$a$'\t'$b$nl ;;
		*) say "config: unknown keyword '$kw'" ;;
		esac
	done <"$SRCSYNC_CONFIG"
}

# True when any line of $1 contains any pattern in the list $2, ignoring
# case: GitHub and Bitbucket owner names do, so UpNGo clones as well as upngo.
matches_any() { # text patterns
	local p t
	t=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
	while IFS= read -r p; do
		[ -n "$p" ] || continue
		case $t in *"$p"*) return 0 ;; esac
	done <<EOF
$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')
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

# Two tab-separated fields for the repo and worktree that hold $1: repo_dir,
# the physical path of the repo's main worktree, and wt_dir, the physical path
# of the worktree top. Fails, printing nothing, when $1 is not inside a git
# worktree, or its repo is not one find_repos would list.
resolve_path() { # path
	local path=$1 gcd repo_dir wt_dir src_p rel
	gcd=$(git -C "$path" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
	repo_dir=$(cd "$gcd/.." 2>/dev/null && pwd -P) || return 1
	wt_dir=$(git -C "$path" rev-parse --show-toplevel 2>/dev/null) || return 1
	wt_dir=$(cd "$wt_dir" 2>/dev/null && pwd -P) || return 1
	src_p=$(cd "$SRCSYNC_SRC" 2>/dev/null && pwd -P) || return 1
	case $repo_dir in
	"$src_p"/*) rel=${repo_dir#"$src_p"/} ;;
	*) return 1 ;;
	esac
	case $rel in
	*/*/*) return 1 ;;
	esac
	printf '%s\t%s\n' "$repo_dir" "$wt_dir"
}

snap_ref() { # host key
	printf 'refs/srcsync/%s/%s/tree\n' "$1" "$2"
}

# The host and owner of a remote URL, tab-separated, for the scp form
# host:owner/repo and the URL form scheme://host/owner/repo, with any user and
# port dropped. Prints nothing for a local path.
url_host_owner() { # url
	local u=$1 host path
	case $u in
	*://*)
		u=${u#*://}
		host=${u%%/*}
		path=${u#"$host"}
		host=${host##*@}
		host=${host%%:*}
		;;
	/* | ./* | ../*) return 0 ;;
	*:*)
		host=${u%%:*}
		case $host in */*) return 0 ;; esac
		path=${u#*:}
		host=${host##*@}
		;;
	*) return 0 ;;
	esac
	while :; do case $path in /*) path=${path#/} ;; *) break ;; esac; done
	printf '%s\t%s\n' "$host" "${path%%/*}"
}

# True when some worktree of the repo has changes git status shows, untracked
# included, or a local branch has commits no remote-tracking ref reaches.
has_local_changes() { # repo_dir
	local wt
	[ -n "$(git -C "$1" rev-list -1 --branches --not --remotes 2>/dev/null)" ] && return 0
	while IFS= read -r wt; do
		[ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ] && return 0
	done < <(git -C "$1" worktree list --porcelain | sed -n 's/^worktree //p')
	return 1
}

# hub, origin, ignore, or skip:<reason>. The company test runs first and
# returns, so no override below it can send a company repo to the personal hub.
# ignore is for repos not worth carrying, and unlike skip is never reported:
# the timer walks every repo every few minutes.
#
# Routing reads each URL both as configured and as git rewrites it through
# url.<base>.insteadOf, so a rewrite can neither hide a company match nor
# invent a forge.
sync_target() { # repo_dir key
	local urls origin raw origin_on_forge=false owned=false name url host owner override
	urls=$({
		git -C "$1" remote -v | awk '{print $2}'
		git -C "$1" config --get-regexp '^remote\..*\.url$' | awk '{print $2}'
	} | sort -u)
	origin=$(git -C "$1" remote get-url origin 2>/dev/null) || origin=""
	raw=$(git -C "$1" config --get remote.origin.url) || raw=""
	# origin must be on the forge; an owner on any forge remote counts, so a
	# clone of upstream with a fork added as another remote is still owned
	while read -r name url; do
		[ -n "$name" ] || continue
		IFS=$'\t' read -r host owner <<<"$(url_host_owner "$url")"
		[ -n "$host" ] && on_forge "$host" || continue
		[ "$name" = remote.origin.url ] && origin_on_forge=true
		[ -n "$owner" ] && is_owner "$owner" && owned=true
	done < <(git -C "$1" config --get-regexp '^remote\..*\.url$')
	if matches_any "$urls" "$CFG_COMPANY"; then
		if [ -z "$raw" ]; then
			echo "skip:company repo with no origin"
		elif [ $origin_on_forge = false ]; then
			echo ignore
		elif matches_any "$origin"$'\n'"$raw" "$CFG_TEAM"; then
			echo "skip:origin is the team repo, fork it first"
		else
			echo origin
		fi
		return
	fi
	override=$(printf '%s' "$CFG_OVERRIDES" | awk -F'\t' -v k="$2" '$1 == k { v = $2 } END { print v }')
	case $override in
	skip) echo ignore ;;
	origin) if [ -n "$raw" ]; then echo origin; else echo hub; fi ;;
	hub) echo hub ;;
	*)
		if [ -n "$(jq -r --arg r "$2" '.repos[$r] // empty | "yes"' "$LAST" 2>/dev/null)" ]; then
			# Sticky, whatever the remotes or the config now say: dropped,
			# the other machine's copy of a discarded change would read as
			# new work here and come back.
			echo hub
		elif [ $origin_on_forge = false ]; then
			echo ignore
		elif [ $owned = true ] || has_local_changes "$1"; then
			echo hub
		else
			echo ignore
		fi
		;;
	esac
}

# True when $1 is a forge host, ignoring case: the host itself, or an ssh
# alias for it such as github.com-batsshadow. github.company.com is not.
on_forge() { # host
	local f h
	h=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
	while IFS= read -r f; do
		[ -n "$f" ] || continue
		case $h in "$f" | "$f"-*) return 0 ;; esac
	done <<EOF
$(printf '%s' "${CFG_FORGE:-github.com}" | tr '[:upper:]' '[:lower:]')
EOF
	return 1
}

# True when $1 is one of the owner lines, ignoring case.
is_owner() { # account
	local o t
	t=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
	while IFS= read -r o; do
		[ "$o" = "$t" ] && return 0
	done <<EOF
$(printf '%s' "$CFG_OWNER" | tr '[:upper:]' '[:lower:]')
EOF
	return 1
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
