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

# The worktree's state as JSON, or null when there is no worktree. One that is
# there but unreadable, such as a repo with no commits yet, fails instead: taken
# for absent, it would be applied over.
now_json() { # wt
	local st b h t tr c
	if [ ! -e "$1/.git" ]; then
		echo null
		return
	fi
	st=$(worktree_state "$1") || return 1
	IFS=$'\t' read -r b h t tr <<<"$st"
	st=$(state_json "$b" "$h" "$t" "$tr")
	if [ "$CFG_TRANSCRIPTS" = on ]; then
		c=$(claude_tree "$1" "$1") || return 1
		st=$(with_claude "$st" "$c")
	fi
	printf '%s\n' "$st"
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
# ref so every entry names a commit its own host has pushed. With transcripts
# on, claude is the tree laid here, under this host's claude ref.
record_theirs() { # repo_dir repo_key wt_key theirs_json
	local snap c
	if [ "$CFG_TRANSCRIPTS" = on ]; then
		c=$(own_claude "$1" "$3" "$4") || c=null
		[ "$c" = null ] || mark_pending "$2"
		set_mine "$2" "$3" "$(jq -c --argjson c "$c" \
			'{branch, head, tracking, tree, claude: $c, snapshot, changed_at, base: {branch, head, tree, claude}}' <<<"$4")"
	else
		set_mine "$2" "$3" "$(jq -c \
			'{branch, head, tracking, tree, snapshot, changed_at, base: {branch, head, tree}}' <<<"$4")"
	fi
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
# there is one, or else the head, from whichever remote has it. With
# transcripts on, the claude ref too.
fetch_theirs() { # repo_dir sync host theirs_json
	local ref snap head claude
	snap=$(jq -r .snapshot <<<"$4")
	head=$(jq -r .head <<<"$4")
	if [ "$snap" != null ]; then
		ref=$(snap_ref "$3" "$(jq -r .key <<<"$4")")
		git -C "$1" fetch -q --no-tags "$(target_url "$2")" "+$ref:$ref" 2>/dev/null || return 1
		# The ref is pushed before the state file, so the two can disagree
		# for a run. The next one sees them match.
		[ "$(git -C "$1" rev-parse -q --verify "$ref")" = "$snap" ] || return 1
	elif ! git -C "$1" cat-file -e "$head^{commit}" 2>/dev/null; then
		git -C "$1" fetch -q --all --no-tags 2>/dev/null
		git -C "$1" cat-file -e "$head^{commit}" 2>/dev/null || return 1
	fi
	claude=$(jq -r '.claude // null' <<<"$4")
	[ "$CFG_TRANSCRIPTS" = on ] && [ "$claude" != null ] || return 0
	ref=$(claude_ref "$3" "$(jq -r .key <<<"$4")")
	git -C "$1" fetch -q --no-tags "$(target_url "$2")" "+$ref:$ref" 2>/dev/null || return 1
	# pushed before the state file, like the snapshot
	[ "$(git -C "$1" rev-parse -q --verify "$ref^{tree}")" = "$claude" ]
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

# A transcript file both sides hold with different content, when there is no
# base to say which is newer: first contact, or neither side built on the
# other. Laying theirs would overwrite this machine's copy.
first_contact_clash() { # repo_dir wt mine_json theirs_json
	local tc
	[ "$CFG_TRANSCRIPTS" = on ] || return 0
	tc=$(jq -r '.claude // empty' <<<"$4")
	[ -n "$tc" ] || return 0
	jq -e --argjson t "$4" '. == null or (.base == null and $t.base == null)' <<<"$3" >/dev/null || return 0
	claude_disagree "$1" "$2" "$tc"
}

# Both sides moved: nothing changes, and status and the picker see it.
record_conflict() { # repo_key wt_key host now_json theirs_json message
	say "$2: $6; left alone"
	jq -cn --arg r "$1" --arg w "$2" --arg h "$3" --argjson mine "$4" \
		--argjson theirs "$5" '{repo: $r, worktree: $w, host: $h, mine: $mine, theirs: $theirs}' \
		>>"$CONFLICTS.tmp"
}

# True when the local branch theirs would switch to holds commits theirs lacks,
# which checkout -B would drop. decide.jq only sees the current branch. A ref
# at the head this machine last published is safe: the hub or origin has it,
# so an amend or rebase on the other side still applies.
branch_diverged() { # repo_dir theirs_json published_head
	local branch head ref
	branch=$(jq -r .branch <<<"$2") head=$(jq -r .head <<<"$2")
	[ "$branch" != null ] || return 1
	ref=$(git -C "$1" rev-parse -q --verify "refs/heads/$branch^{commit}") || return 1
	[ "$ref" != "$head" ] && [ "$ref" != "$3" ] &&
		! git -C "$1" merge-base --is-ancestor "$ref" "$head"
}

# Commits the worktree as it is to a local ref before a checkout overwrites it.
# The ref is outside refs/srcsync/<host>, so push_pending never sends it.
save_before_apply() { # repo_dir wt_key wt now_json
	local tree head branch tracking snap
	tree=$(jq -r .tree <<<"$4") head=$(jq -r .head <<<"$4")
	branch=$(jq -r '.branch // "-"' <<<"$4") tracking=$(jq -r '.tracking // "-"' <<<"$4")
	snap=$(make_snapshot "$3" "$2" "$tree" "$head" "$branch" "$tracking") || return 1
	git -C "$1" update-ref --create-reflog -m "srcsync before apply" \
		"refs/srcsync-local/$2/before-apply" "$snap"
}

# The transcripts on disk, kept beside the code's before-apply ref, since
# laying theirs overwrites any file here it extends. Read from the directory,
# not the worktree's state: it outlives a removed worktree, and files over the
# cap are kept too, since the ref is never pushed.
save_claude_before_apply() { # repo_dir wt_key wt
	local tree commit
	tree=$(claude_scan "$1" "$3" all) || return 1
	[ -n "$tree" ] || return 0
	commit=$(make_claude_commit "$1" "$2" "$tree") || return 1
	git -C "$1" update-ref --create-reflog -m "srcsync before apply" \
		"refs/srcsync-local/$2/claude-before-apply" "$commit"
}

# With transcripts off here, claude is dropped from every side, bases too, so
# code alone decides. Otherwise the other machine's transcripts would read as a
# change this one can never match, and it would apply on every run.
decide() { # mine now theirs removed_at ff_forward ff_back
	local strip=.
	[ "$CFG_TRANSCRIPTS" = on ] || strip='(.mine, .now, .theirs) |= (if . == null then . else del(.claude) | (.base |= if . == null then . else del(.claude) end) end)'
	jq -cn --argjson mine "$1" --argjson now "$2" --argjson theirs "$3" \
		--argjson removed_at "$4" --argjson ff_forward "$5" --argjson ff_back "$6" \
		'{$mine, $now, $theirs, $removed_at, $ff_forward, $ff_back}' | jq -c "$strip" | jq -r -f "$DECIDE"
}

# Overwrites the worktree with theirs, which the caller has fetched. The fetch
# takes seconds, so the busy check and the touched check both run after it,
# just before anything is overwritten. A clone made just now holds nothing of
# this machine's to protect. Fails with 2, saying nothing, when theirs' branch
# holds commits here that theirs lacks, and with 1 for anything else, saying
# why and when to retry ($9).
take_theirs() { # host repo_dir repo_key wt_key theirs_json now_json published_head cloned retry
	local host=$1 repo=$2 rkey=$3 wkey=$4 theirs=$5 now=$6 wt=$HOME_P/$4 again=null claude= clash=
	if claude_busy "$wt"; then
		say "$wkey: Claude is working there; $9"
		return 1
	fi
	if [ "$8" = false ]; then
		again=$(now_json "$wt") || again=unreadable
		if [ "$again" != "$now" ]; then
			say "$wkey: changed while applying; $9"
			return 1
		fi
	fi
	branch_diverged "$repo" "$theirs" "$7" && return 2
	[ "$CFG_TRANSCRIPTS" = on ] && claude=$(jq -r '.claude // empty' <<<"$theirs")
	[ -n "$claude" ] && clash=$(claude_clash "$repo" "$wt" "$claude")
	if [ -n "$clash" ]; then
		say "$wkey: $clash in its transcripts is in the way; skipped"
		return 1
	fi
	if [ "$again" != null ]; then
		save_before_apply "$repo" "$wkey" "$wt" "$again" || {
			say "$wkey: cannot save it before applying; skipped"
			return 1
		}
	fi
	if [ -n "$claude" ]; then
		save_claude_before_apply "$repo" "$wkey" "$wt" || {
			say "$wkey: cannot save its transcripts before applying; skipped"
			return 1
		}
	fi
	apply_worktree "$repo" "$wt" "$theirs" || {
		say "$wkey: apply failed"
		return 1
	}
	if [ -n "$claude" ]; then
		lay_claude "$repo" "$wt" "$claude" || {
			say "$wkey: applied the code, but its transcripts failed"
			return 1
		}
	fi
	[ "$(jq -r .tree <<<"$(now_json "$wt")")" = "$(jq -r .tree <<<"$theirs")" ] ||
		say "$wkey: applied, but the result differs from $host's tree"
	record_theirs "$repo" "$rkey" "$wkey" "$theirs"
	say "$wkey: took $host's state"
	[ -z "$claude" ] || [ "$CLAUDE_LAID" = 0 ] || restart_idle "$wt"
}

# One worktree of one repo from the other machine.
apply_one() { # host repo_key repo_json wt_key
	local host=$1 rkey=$2 rjson=$3 wkey=$4 repo wt theirs mine now removed sync decision fwd back
	local fetched=false cloned=false clash
	repo=$HOME_P/$rkey wt=$HOME_P/$wkey
	theirs=$(jq -c --arg w "$wkey" '.worktrees[$w] + {key: $w}' <<<"$rjson")
	sync=$(jq -r .sync <<<"$rjson")
	mine=$(jq -c --arg r "$rkey" --arg w "$wkey" '.repos[$r].worktrees[$w] // null' "$LAST")
	removed=$(jq -c --arg r "$rkey" --arg w "$wkey" '.repos[$r].removed[$w] // null' "$LAST")
	now=$(now_json "$wt") || {
		say "$wkey: cannot read it here; skipped"
		return
	}

	decision=$(decide "$mine" "$now" "$theirs" "$removed" null null)
	if [ "$decision" = check-ff ]; then
		fetch_theirs "$repo" "$sync" "$host" "$theirs" || {
			say "$wkey: cannot fetch $host's state yet"
			return
		}
		fetched=true
		read -r fwd back < <(ff_flags "$wt" "$now" "$theirs")
		decision=$(decide "$mine" "$now" "$theirs" "$removed" "$fwd" "$back")
	fi

	case $decision in
	same)
		if [ "$mine" = null ]; then
			fetch_theirs "$repo" "$sync" "$host" "$theirs" &&
				record_theirs "$repo" "$rkey" "$wkey" "$theirs"
		elif ! jq -e --argjson t "$theirs" ".base == (\$t | $(base_keys))" <<<"$mine" >/dev/null; then
			set_mine "$rkey" "$wkey" "$(jq -c --argjson t "$theirs" \
				".base = (\$t | $(base_keys))" <<<"$mine")"
		fi
		;;
	conflict)
		# for the picker's preview; the conflict stands either way
		[ $fetched = true ] || fetch_theirs "$repo" "$sync" "$host" "$theirs" || true
		record_conflict "$rkey" "$wkey" "$host" "$now" "$theirs" "changed here and on $host"
		;;
	apply)
		if [ ! -d "$repo" ]; then
			clone_repo "$repo" "$(jq -r .origin <<<"$rjson")" "$(jq -r .upstream <<<"$rjson")" || {
				say "$rkey: clone failed"
				return
			}
			cloned=true
		fi
		if [ $fetched = false ]; then
			fetch_theirs "$repo" "$sync" "$host" "$theirs" || {
				say "$wkey: cannot fetch $host's state yet"
				return
			}
		fi
		clash=$(first_contact_clash "$repo" "$wt" "$mine" "$theirs")
		if [ -n "$clash" ]; then
			record_conflict "$rkey" "$wkey" "$host" "$now" "$theirs" \
				"transcript $clash differs here and on $host"
			return
		fi
		take_theirs "$host" "$repo" "$rkey" "$wkey" "$theirs" "$now" \
			"$(jq -r '.head // ""' <<<"$mine")" $cloned "next run"
		[ $? = 2 ] && record_conflict "$rkey" "$wkey" "$host" "$now" "$theirs" \
			"branch $(jq -r .branch <<<"$theirs") has commits here that $host lacks"
		;;
	esac
}

# Copies the untracked files in $2 that the config excludes, at any depth, into
# the state dir. They were never snapshotted, and worktree remove --force would
# delete the only copy. Prints the count, and fails if the listing or any copy
# does. The listing goes through a file so its exit status is seen: an empty
# read from a failed ls-files would pass for "nothing to keep".
keep_excluded() { # wt_key wt
	local dest ex=() p f n=0 list rc=0
	while IFS= read -r p; do [ -n "$p" ] && ex+=("--exclude=$p"); done <<EOF
$CFG_EXCLUDE
EOF
	[ ${#ex[@]} -gt 0 ] || {
		echo 0
		return
	}
	dest=$SRCSYNC_STATE/removed/$1/$(date -u +%Y-%m-%dT%H%M%SZ)
	list=$(mktemp "${TMPDIR:-/tmp}/srcsync-excluded.XXXXXX") || return 1
	if git -C "$2" ls-files -z -o -i "${ex[@]}" >"$list"; then
		while IFS= read -r -d '' f; do
			mkdir -p "$dest/$(dirname "$f")" && cp -p "$2/$f" "$dest/$f" || {
				rc=1
				break
			}
			n=$((n + 1))
		done <"$list"
	else
		rc=1
	fi
	rm -f "$list"
	[ $rc = 0 ] && echo "$n $dest"
}

# The other machine removed a linked worktree. Follow if the removal is no
# older than this machine's last change to it, nothing changed here since this
# machine published it, and no Claude is working there. A main worktree is a
# whole repo and is never deleted.
apply_removal() { # host repo_key wt_key removed_at
	local repo=$HOME_P/$2 wt=$HOME_P/$3 mine now kept n dir
	[ -f "$wt/.git" ] || return 0
	mine=$(jq -c --arg r "$2" --arg w "$3" '.repos[$r].worktrees[$w] // null' "$LAST")
	[ "$mine" != null ] || return 0
	[[ $4 < $(jq -r .changed_at <<<"$mine") ]] && return 0
	now=$(now_json "$wt") || {
		say "$3: cannot read it here; skipped"
		return 0
	}
	if ! same_state "$mine" "$now"; then
		say "$3: removed on $1 but changed here; kept"
		return 0
	fi
	if claude_busy "$wt"; then
		say "$3: Claude is working there; next run"
		return 0
	fi
	kept=$(keep_excluded "$3" "$wt") || {
		say "$3: could not save its excluded files; kept"
		return 0
	}
	read -r n dir <<<"$kept"
	[ "$n" = 0 ] || say "$3: kept $n excluded files in $dir"
	git -C "$repo" worktree remove --force "$wt" && say "$3: removed, as on $1"
}

cmd_apply() { # [wt_dir]
	local f host rkey rjson wkey at wt=${1:-} resolved wt_key
	ensure_last
	hub_update || {
		say "cannot reach the hub"
		return 1
	}
	if [ -n "$wt" ]; then
		resolved=$(resolve_path "$wt") || return 1
		rkey=$(key_of "${resolved%%$'\t'*}") || return 1
		wt_key=$(key_of "${resolved#*$'\t'}") || return 1
	fi
	: >"$CONFLICTS.tmp"
	if [ -n "$wt" ] && [ -f "$CONFLICTS" ]; then
		jq -c --arg w "$wt_key" '.[] | select(.worktree != $w)' "$CONFLICTS" >>"$CONFLICTS.tmp"
	fi
	for f in "$HUB_DIR"/machines/*.json; do
		[ -f "$f" ] || continue
		host=$(jq -r .host "$f")
		# a machine that shares this one's id wrote it; never take it
		[ "$host" = "$SRCSYNC_HOST" ] || [ "$f" = "$HUB_DIR/machines/$SRCSYNC_HOST.json" ] && continue
		if [ -n "$wt" ]; then
			rjson=$(jq -c --arg r "$rkey" '.repos[$r]' "$f")
			jq -e --arg w "$wt_key" '(.worktrees // {})[$w] != null' <<<"$rjson" >/dev/null 2>&1 &&
				apply_one "$host" "$rkey" "$rjson" "$wt_key"
			continue
		fi
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
