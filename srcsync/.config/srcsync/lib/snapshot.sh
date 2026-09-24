# Reading a worktree's state without disturbing it, and writing it down as one
# commit. See DESIGN.md "Snapshots".

# The configured excludes as pathspecs matching at any depth. $1 is the magic:
# "exclude,glob" to leave them out of an add, "glob" to find them. The second
# spec covers a directory's contents, which the first does not match.
exclude_specs() { # magic
	local p
	while IFS= read -r p; do
		[ -n "$p" ] && printf ':(%s)**/%s\n:(%s)**/%s/**\n' "$1" "$p" "$1" "$p"
	done <<EOF
$CFG_EXCLUDE
EOF
}

# The tree the worktree at $1 would snapshot to: tracked and untracked files,
# minus ignored ones and untracked excluded ones. A tracked file is already in
# history, so an exclude never hides an edit to it: hidden, the edit read as
# untouched and apply overwrote it. It works on a copy of the real index, so git
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
		if [ ${#in[@]} -gt 0 ]; then
			# add -u fails on a pathspec that matches nothing, so it gets
			# the tracked names instead
			git ls-files -z -- "${in[@]}" >"$tmp.names" || exit 1
			if [ -s "$tmp.names" ]; then
				git --literal-pathspecs add -u --pathspec-from-file="$tmp.names" \
					--pathspec-file-nul || exit 1
			fi
			# An excluded file staged but never committed is still in the
			# copy. Drop it, but never one HEAD has: that would publish a delete.
			git diff --cached --no-renames --name-only --diff-filter=A -z HEAD -- "${in[@]}" |
				xargs -0 git rm -q --cached --ignore-unmatch -- 2>/dev/null
		fi
		git write-tree
	)
	local rc=$?
	rm -f "$tmp" "$tmp.names"
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

# True when entry $1 records state $2: the same fields, and a claude key only
# when $2 has one, so turning transcripts on or off republishes.
same_state() { # entry_json state_json
	jq -e --argjson n "$2" \
		'with_entries(select(.key | IN("branch", "head", "tracking", "tree", "claude"))) == $n' \
		<<<"$1" >/dev/null
}

# $1 with claude set to tree $2, or null when $2 is empty.
with_claude() { # state_json tree
	jq -c --arg c "$2" '. + {claude: (if $c == "" then null else $c end)}' <<<"$1"
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

# Bytes on disk of every object pushing the commits would send: all they reach
# that the target is not known to hold. The target holds every srcsync ref this
# repo has, and origin also holds its branches. The hub holds nothing else, so the
# first hub push of a cloned repo counts its whole history, which is exactly
# what the hub would receive.
push_size() { # repo_dir target commit...
	local repo=$1 not=(--glob='refs/srcsync/*')
	[ "$2" = origin ] && not+=(--remotes=origin)
	shift 2
	git -C "$repo" rev-list --objects --disk-usage "$@" --not "${not[@]}"
}
