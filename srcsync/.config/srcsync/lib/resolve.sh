# Settling a conflict apply recorded: take theirs, or keep mine and have the
# other machine take it. See DESIGN.md "When not to apply".

# One line per conflict: worktree, host, mine and theirs each as host,
# branch@head and tree, then the worktree's path and the two trees for the
# picker's preview. The tree tells apart two sides on one head, the usual
# case, where only uncommitted work differs.
conflict_rows() {
	[ -f "$CONFLICTS" ] || return 0
	jq -r --arg home "$HOME_P" --arg me "$SRCSYNC_HOST" '
		def at($h): "\($h) \(.branch // "(detached)")@\(.head[0:7]) tree \(.tree[0:7])";
		.[] | .host as $h | [.worktree, .host, (.mine | at($me)), (.theirs | at($h)),
			"\($home)/\(.worktree)", .mine.tree, .theirs.tree] | @tsv' "$CONFLICTS"
}

cmd_conflicts() { conflict_rows | cut -f1-4; }

# Publishes one repo and fails only if that repo's own push did. push_pending
# retries every queued repo, so an unrelated one that cannot push is only
# reported.
publish_one() { # repo_dir repo_key
	local r
	cmd_publish "$1"
	[ -f "$PENDING" ] && while IFS= read -r r; do
		[ -n "$r" ] && [ "$r" != "$2" ] && say "$r is still unpushed; the next publish retries it"
	done <"$PENDING"
	! grep -qxF "$2" "$PENDING" 2>/dev/null
}

drop_conflict() { # wt_key
	jq --arg w "$1" 'map(select(.worktree != $w))' "$CONFLICTS" >"$CONFLICTS.tmp" &&
		mv "$CONFLICTS.tmp" "$CONFLICTS"
}

# Theirs as the hub has it now, if it is still the state the conflict named.
# A newer one was never shown in the picker, so the next apply decides it.
current_theirs() { # host repo_key wt_key recorded_theirs
	local f=$HUB_DIR/machines/$1.json
	[ -f "$f" ] || return 1
	jq -ce --arg r "$2" --arg w "$3" --argjson t "$4" "
		.repos[\$r] as \$repo | (\$repo.worktrees // {})[\$w]
		| select(. != null and $(base_keys) == (\$t | $(base_keys)))
		| . + {key: \$w, sync: \$repo.sync}" "$f"
}

resolve_theirs() { # repo_dir repo_key wt_key conflict_json
	local repo=$1 rkey=$2 wkey=$3 host theirs now mine_head rc
	host=$(jq -r .host <<<"$4")
	hub_update || {
		say "cannot reach the hub"
		return 1
	}
	theirs=$(current_theirs "$host" "$rkey" "$wkey" "$(jq -c .theirs <<<"$4")") || {
		say "$wkey: $host changed it again since; run apply"
		return 1
	}
	now=$(now_json "$HOME_P/$wkey") || {
		say "$wkey: cannot read it here"
		return 1
	}
	fetch_theirs "$repo" "$(jq -r .sync <<<"$theirs")" "$host" "$theirs" || {
		say "$wkey: cannot fetch $host's state yet"
		return 1
	}
	mine_head=$(jq -r --arg r "$rkey" --arg w "$wkey" '.repos[$r].worktrees[$w].head // ""' "$LAST")
	take_theirs "$host" "$repo" "$rkey" "$wkey" "$theirs" "$now" "$mine_head" false "not resolved"
	rc=$?
	if [ $rc = 2 ]; then
		say "$wkey: branch $(jq -r .branch <<<"$theirs") has commits here that $host lacks; not resolved"
	fi
	[ $rc = 0 ] || return 1
	drop_conflict "$wkey"
	if ! publish_one "$repo" "$rkey" || [ -f "$HUB_PENDING" ]; then
		say "$wkey: resolved here; $host hears of it on the next publish"
		return 1
	fi
}

# Publishes this side as it is, then bases it on theirs, which is what tells
# the other machine's apply that this side moved on from theirs.
resolve_mine() { # repo_dir repo_key wt_key conflict_json
	local rkey=$2 wkey=$3 entry
	publish_one "$1" "$rkey" || {
		say "$wkey: push failed; not resolved"
		return 1
	}
	entry=$(jq -c --arg r "$rkey" --arg w "$wkey" '.repos[$r].worktrees[$w] // empty' "$LAST")
	[ -n "$entry" ] || {
		say "$wkey: not in this machine's publish; not resolved"
		return 1
	}
	set_mine "$rkey" "$wkey" "$(jq -c --argjson c "$4" ".base = (\$c.theirs | $(base_keys))" <<<"$entry")"
	drop_conflict "$wkey"
	if hub_publish "$LAST"; then
		rm -f "$HUB_PENDING"
	else
		say "$wkey: resolved here; the hub hears of it on the next publish"
		return 1
	fi
}

cmd_resolve() { # path theirs|mine
	local resolved repo rkey wkey conflict
	case ${2:-} in
	theirs | mine) ;;
	*)
		echo "usage: srcsync.sh resolve <path> theirs|mine" >&2
		return 2
		;;
	esac
	resolved=$(resolve_path "$1") || {
		say "$1: not a synced repo"
		return 1
	}
	repo=${resolved%%$'\t'*}
	rkey=$(key_of "$repo") || return 1
	wkey=$(key_of "${resolved#*$'\t'}") || return 1
	conflict=$(jq -c --arg w "$wkey" '.[] | select(.worktree == $w)' "$CONFLICTS" 2>/dev/null | head -1)
	[ -n "$conflict" ] || {
		say "$wkey: no conflict"
		return 1
	}
	ensure_last
	"resolve_$2" "$repo" "$rkey" "$wkey" "$conflict"
}

# fzf over the conflicts. enter takes theirs, ctrl-k keeps mine. resolve runs
# as its own srcsync.sh, which takes the lock and drops it on exit, so no run
# is locked out while fzf or the key press waits. The waits for a key are for
# the tmux popup, which would otherwise close before it is read.
cmd_pick() {
	local rows out key row choice
	rows=$(conflict_rows)
	if [ -z "$rows" ]; then
		echo "no conflicts"
		read -rsn1
		return 0
	fi
	command -v fzf >/dev/null || {
		echo "pick needs fzf"
		read -rsn1
		return 1
	}
	out=$(printf '%s\n' "$rows" | fzf --delimiter='\t' --with-nth=1,2,3,4 --expect=ctrl-k \
		--header='enter: take theirs   ctrl-k: keep mine' \
		--preview="git -C {5} diff --stat {6} {7} 2>/dev/null || echo 'their snapshot is not here yet'") ||
		return 0
	key=$(sed -n 1p <<<"$out") row=$(sed -n 2p <<<"$out")
	[ -n "$row" ] || return 0
	if [ "$key" = ctrl-k ]; then choice=mine; else choice=theirs; fi
	/bin/bash "$LIB/../srcsync.sh" resolve "$(cut -f5 <<<"$row")" "$choice"
	echo "press a key"
	read -rsn1
}
