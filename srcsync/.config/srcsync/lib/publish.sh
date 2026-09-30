# Publish: snapshot every worktree that changed, push the snapshots, and
# rewrite this machine's file in the hub. See DESIGN.md "The state file".

# Something went wrong with a worktree this run. The run must not count as a
# success, and the worktree must not read as removed.
publish_failed() { say "$1"; touch "$SRCSYNC_STATE/publish-failed"; }

# Every repo up to two levels under ~/src.
find_repos() {
	find "$SRCSYNC_SRC" -mindepth 2 -maxdepth 3 -name .git -type d -prune 2>/dev/null |
		sed 's#/\.git$##' | sort
}

# Every live worktree of a repo, main first, as git reports it, less any that
# belong to another repo. A repo copied with cp -R still lists the original's
# worktrees, whose .git points at the original, so their snapshots landed in
# the original's objects and the copy published them as its own.
find_worktrees() { # repo_dir
	local own wt
	own=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir) || return
	own=$(cd "$own" && pwd -P)
	git -C "$1" worktree list --porcelain | awk '
		/^worktree / { p = substr($0, 10) }
		/^bare$/ || /^prunable/ { p = "" }
		/^$/ { if (p != "") print p; p = "" }
		END { if (p != "") print p }' |
		while IFS= read -r wt; do
			[ "$(cd "$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P)" = "$own" ] &&
				printf '%s\n' "$wt"
		done
}

# True when the hub clone is mid-rebase, mid-merge or has stray edits, as a
# run stopped inside pull --rebase leaves it.
hub_stuck() {
	local g
	g=$(git -C "$HUB_DIR" rev-parse --absolute-git-dir) || return 0
	[ -d "$g/rebase-merge" ] || [ -d "$g/rebase-apply" ] || [ -f "$g/MERGE_HEAD" ] ||
		[ -n "$(git -C "$HUB_DIR" status --porcelain)" ]
}

# Puts the hub clone on the hub's main, dropping anything local. It holds
# nothing last.json cannot rebuild: every publish rewrites this machine's file
# from it, and left stuck, every run failed with "cannot reach the hub".
hub_reset() {
	git -C "$HUB_DIR" rebase --quit >/dev/null 2>&1
	git -C "$HUB_DIR" merge --quit >/dev/null 2>&1
	git -C "$HUB_DIR" fetch -q origin main &&
		git -C "$HUB_DIR" checkout -q -f -B main FETCH_HEAD &&
		git -C "$HUB_DIR" clean -fdq
}

# The hub clone, up to date with the remote, or a failure when the hub cannot
# be reached. A hub nobody has pushed to yet has no main, and there is nothing
# to pull. A pull that stops on a conflict
# resets, since this machine's file is rewritten on the next publish anyway.
hub_update() {
	if [ ! -d "$HUB_DIR/.git" ]; then
		git clone -q "$SRCSYNC_HUB" "$HUB_DIR" 2>/dev/null || return 1
	fi
	# 2 is a hub with no main; anything else is a hub it cannot reach
	git -C "$HUB_DIR" ls-remote --exit-code origin refs/heads/main >/dev/null 2>&1
	case $? in
	0) ;;
	2) return 0 ;;
	*) return 1 ;;
	esac
	if hub_stuck; then
		hub_reset || return 1
	fi
	git -C "$HUB_DIR" pull -q --rebase origin main >/dev/null 2>&1 || hub_reset
}

# The other machine can push between this one's pull and push, as two Stop
# hooks at once do, so a rejected push pulls again and retries. Each machine
# writes only its own file, so the rebase conflicts only when two share an id.
# The file is copied again after every pull, since a pull that reset the clone
# dropped the commit holding it.
hub_publish() { # machine_json_file
	for _ in 1 2 3; do
		hub_update || return 1
		mkdir -p "$HUB_DIR/machines"
		cp "$1" "$HUB_DIR/machines/$SRCSYNC_HOST.json"
		git -C "$HUB_DIR" add machines
		if ! git -C "$HUB_DIR" diff --cached --quiet; then
			git -C "$HUB_DIR" commit -q -m "publish $SRCSYNC_HOST" || return 1
		fi
		git -C "$HUB_DIR" push -q origin HEAD:main && return 0
	done
	return 1
}

# The last publish's entry, printed back when this one cannot replace it.
keep_prev() { [ "$1" != null ] && printf '%s\n' "$1"; }

# One worktree's entry as a line of JSON, or nothing when it cannot be
# published. Changed worktrees get a snapshot and a local ref, and with
# transcripts on a claude commit and ref when the transcripts moved; the push
# is left to push_pending, once per repo.
publish_worktree() { # repo_dir repo_key target wt
	local repo=$1 rkey=$2 target=$3 wt=$4 wkey st branch head tracking tree prev now_st snap size
	local ctree= ccommit= pclaude
	wkey=$(key_of "$wt") || {
		say "$wt is outside \$HOME, skipped"
		return
	}
	git check-ref-format "$(snap_ref "$SRCSYNC_HOST" "$wkey")" || {
		say "$wkey cannot be a ref name, skipped"
		return
	}
	prev=$(jq -c --arg r "$rkey" --arg w "$wkey" '.repos[$r].worktrees[$w] // null' "$LAST")

	st=$(worktree_state "$wt") || {
		if [ "$prev" != null ]; then
			publish_failed "$wkey: cannot read its state; keeping the last publish"
			printf '%s\n' "$prev"
		else
			say "$wkey has no commits yet, skipped"
		fi
		return
	}
	IFS=$'\t' read -r branch head tracking tree <<<"$st"
	now_st=$(state_json "$branch" "$head" "$tracking" "$tree")
	if [ "$CFG_TRANSCRIPTS" = on ]; then
		ctree=$(claude_tree "$repo" "$wt") || {
			publish_failed "$wkey: cannot read its transcripts; keeping the last publish"
			keep_prev "$prev"
			return
		}
		pclaude=$(jq -r '.claude // ""' <<<"$prev")
		if [ -n "$ctree" ] && [ "$ctree" != "$pclaude" ]; then
			ccommit=$(make_claude_commit "$repo" "$wkey" "$ctree") || {
				publish_failed "$wkey: transcript commit failed; keeping the last publish"
				keep_prev "$prev"
				return
			}
		fi
		now_st=$(with_claude "$now_st" "$ctree")
	fi

	if [ "$prev" != null ] && same_state "$prev" "$now_st"; then
		printf '%s\n' "$prev"
		return
	fi

	snap=null
	if [ "$prev" != null ] && same_state "$(jq -c 'del(.claude)' <<<"$prev")" "$(jq -c 'del(.claude)' <<<"$now_st")"; then
		# Only the transcripts moved: the code's snapshot still stands.
		snap=$(jq -c .snapshot <<<"$prev")
	elif [ "$tree" != "$(git -C "$wt" rev-parse "$head^{tree}")" ] || ! on_remote "$wt" "$head"; then
		snap=$(make_snapshot "$wt" "$wkey" "$tree" "$head" "$branch" "$tracking") || {
			publish_failed "$wkey: snapshot failed; keeping the last publish"
			keep_prev "$prev"
			return
		}
		size=$(push_size "$repo" "$target" "$snap")
		if [ "$size" -gt "$CFG_MAX_SIZE" ]; then
			say "$wkey snapshot is $size bytes, over the $CFG_MAX_SIZE byte cap; not published"
			keep_prev "$prev"
			return
		fi
		git -C "$repo" update-ref "$(snap_ref "$SRCSYNC_HOST" "$wkey")" "$snap" || {
			publish_failed "$wkey: snapshot failed; keeping the last publish"
			keep_prev "$prev"
			return
		}
		mark_pending "$rkey"
		snap=\"$snap\"
	fi
	if [ -n "$ccommit" ]; then
		git -C "$repo" update-ref "$(claude_ref "$SRCSYNC_HOST" "$wkey")" "$ccommit" || {
			publish_failed "$wkey: transcript ref failed; keeping the last publish"
			keep_prev "$prev"
			return
		}
		mark_pending "$rkey"
	fi
	jq -c --argjson s "$snap" --arg at "$(now)" --argjson prev "$prev" \
		'. + {snapshot: $s, changed_at: $at, base: ($prev.base // null)}' <<<"$now_st"
}

# Sets ROUTE_TARGET, ROUTE_ORIGIN and ROUTE_UPSTREAM for a repo, or fails for
# one that is not synced, saying why when it is skipped.
repo_route() { # repo_dir repo_key
	ROUTE_TARGET=$(sync_target "$1" "$2")
	case $ROUTE_TARGET in
	ignore) return 1 ;;
	skip:*)
		say "$2 ${ROUTE_TARGET#skip:}"
		return 1
		;;
	esac
	# as configured, not as insteadOf rewrites it: the other machine clones
	# from it, and sync_target routes its clone by the configured URL
	ROUTE_ORIGIN=$(git -C "$1" config --get remote.origin.url) || ROUTE_ORIGIN=""
	ROUTE_UPSTREAM=$(git -C "$1" config --get remote.upstream.url) || ROUTE_UPSTREAM=""
}

# One repo's entry, from its worktrees' entries. Worktrees that were in the
# last publish and are gone now go into removed; removals older than 30 days
# drop out.
repo_entry() { # repo_key target origin upstream worktrees_json
	local cutoff
	cutoff=$(date -u -v-30d +%Y-%m-%dT%H:%M:%SZ)
	jq -c --arg r "$1" --arg o "$3" --arg u "$4" --arg s "$2" \
		--argjson wts "$5" --arg at "$(now)" --arg cutoff "$cutoff" '
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

# One repo's entry, its worktrees visited in the order git lists them.
publish_repo() { # repo_dir
	local repo=$1 rkey wt wkey line wts="{}"
	rkey=$(key_of "$repo") || return
	repo_route "$repo" "$rkey" || return
	while IFS= read -r wt; do
		wkey=$(key_of "$wt") || continue
		line=$(publish_worktree "$repo" "$rkey" "$ROUTE_TARGET" "$wt")
		[ -n "$line" ] || continue
		wts=$(jq -c --arg w "$wkey" --argjson e "$line" '.[$w] = $e' <<<"$wts")
	done < <(find_worktrees "$repo")
	repo_entry "$rkey" "$ROUTE_TARGET" "$ROUTE_ORIGIN" "$ROUTE_UPSTREAM" "$wts"
}

# When the user last touched a worktree, in epoch seconds: the newest of its
# index, its HEAD reflog and its Claude transcripts. Missing files count as 0.
# The slug is claude_dir's, cut without its subshells: a path key_of accepts
# is already physical, and this runs for every worktree on every full run.
touched_at() { # wt
	local f files=() newest=0 m
	while IFS= read -r f; do files+=("$f"); done < <(git -C "$1" rev-parse \
		--path-format=absolute --git-path index --git-path logs/HEAD 2>/dev/null)
	for f in "$CC_PROJECTS_DIR/${1//[^A-Za-z0-9]/-}"/*.jsonl; do
		[ -f "$f" ] && files+=("$f")
	done
	# stat with no operand would read stdin's
	[ ${#files[@]} -gt 0 ] && while IFS= read -r m; do
		[ "$m" -gt "$newest" ] && newest=$m
	done < <(stat -f %m "${files[@]}" 2>/dev/null)
	echo "$newest"
}

# repos with one visited worktree's entry laid over its repo's. A repo new
# since the last publish gets an entry of its own. Nothing is dropped and no
# removal is added: those wait for the end of the run.
checkpoint_entry() { # repos_json repo_key target origin upstream wt_key entry_json
	jq -c --arg r "$2" --arg s "$3" --arg o "$4" --arg u "$5" --arg w "$6" --argjson e "$7" '
		.[$r] = ((.[$r] // {}) as $p | $p + {
			origin: (if $o == "" then null else $o end),
			upstream: (if $u == "" then null else $u end),
			sync: $s,
			worktrees: (($p.worktrees // {}) + {($w): $e}),
			removed: (($p.removed // {}) | del(.[$w]))
		})' <<<"$1"
}

# Pushes the snapshots made so far and writes the hub file from repos, when
# that differs from the last publish. last.json waits for the end of the run.
checkpoint() { # repos_json
	local doc=$SRCSYNC_STATE/checkpoint.json
	cmp -s <(jq -S .repos "$LAST") <(jq -S . <<<"$1") && return 0
	push_pending
	jq --arg h "$SRCSYNC_HOST" --arg at "$(now)" --argjson repos "$1" \
		'{host: $h, published_at: $at, repos: $repos}' "$LAST" >"$doc"
	hub_publish "$doc" || say "checkpoint: hub push failed, the end of the run retries"
	rm -f "$doc"
}

# Every repo's entry, as PUBLISHED_REPOS. Routing is decided once per repo,
# then the worktrees of all of them are visited newest first, so a run cut
# short has already done the work the user just left. The entries come out in
# the order the repos and worktrees were found, whatever the visiting order.
publish_all() {
	local repo rkey wt wkey i j k n=0 nr=0 order line wts since recent visited cp_repos
	local r_dir=() r_key=() r_target=() r_origin=() r_upstream=() w_repo=() w_at=() w_path=() w_key=() w_line=()
	order=$(
		while IFS= read -r repo; do
			rkey=$(key_of "$repo") || continue
			repo_route "$repo" "$rkey" || continue
			printf 'R\t%s\t%s\t%s\t%s\t%s\n' "$repo" "$rkey" "$ROUTE_TARGET" "$ROUTE_ORIGIN" "$ROUTE_UPSTREAM"
			while IFS= read -r wt; do
				wkey=$(key_of "$wt") || continue
				printf 'W\t%s\t%s\t%s\n' "$(touched_at "$wt")" "$wt" "$wkey"
			done < <(find_worktrees "$repo")
		done < <(find_repos)
	)
	# read field by field: an empty origin must not shift the rest
	while IFS= read -r line; do
		case $line in
		R*)
			line=${line#R$'\t'}
			repo=${line%%$'\t'*} line=${line#*$'\t'}
			r_key[nr]=${line%%$'\t'*} line=${line#*$'\t'}
			r_target[nr]=${line%%$'\t'*} line=${line#*$'\t'}
			r_origin[nr]=${line%%$'\t'*}
			r_upstream[nr]=${line#*$'\t'}
			r_dir[nr]=$repo
			nr=$((nr + 1))
			;;
		W*)
			line=${line#W$'\t'}
			w_at[n]=${line%%$'\t'*} line=${line#*$'\t'}
			w_path[n]=${line%%$'\t'*}
			w_key[n]=${line#*$'\t'}
			w_repo[n]=$((nr - 1))
			n=$((n + 1))
			;;
		esac
	done <<<"$order"

	# touched since the last good run; no record of one makes all of them so
	since=$(cat "$LAST_SUCCESS" 2>/dev/null) &&
		since=$(date -u -j -f %Y-%m-%dT%H:%M:%SZ "$since" +%s 2>/dev/null) || since=0
	recent=0
	i=0
	while [ "$i" -lt "$n" ]; do
		[ "${w_at[i]}" -gt "$since" ] && recent=$((recent + 1))
		i=$((i + 1))
	done

	visited=0
	for i in $(i=0; while [ "$i" -lt "$n" ]; do
		printf '%s\t%s\n' "${w_at[i]}" "$i"
		i=$((i + 1))
	done | sort -s -t$'\t' -k1,1nr | cut -f2); do
		j=${w_repo[i]}
		w_line[i]=$(publish_worktree "${r_dir[j]}" "${r_key[j]}" "${r_target[j]}" "${w_path[i]}")
		visited=$((visited + 1))
		# every recent one is done: make them visible before the rest. With
		# all of them recent, the write at the end is as soon.
		[ "$visited" = "$recent" ] && [ "$recent" -lt "$n" ] || continue
		cp_repos=$(jq -c .repos "$LAST")
		k=0
		while [ "$k" -lt "$n" ]; do
			if [ -n "${w_line[k]:-}" ]; then
				j=${w_repo[k]}
				cp_repos=$(checkpoint_entry "$cp_repos" "${r_key[j]}" "${r_target[j]}" \
					"${r_origin[j]}" "${r_upstream[j]}" "${w_key[k]}" "${w_line[k]}")
			fi
			k=$((k + 1))
		done
		checkpoint "$cp_repos"
		[ "${SRCSYNC_STOP_AFTER_CHECKPOINT:-}" = 1 ] && exit 0
	done

	PUBLISHED_REPOS="{}"
	j=0
	while [ "$j" -lt "$nr" ]; do
		wts="{}"
		i=0
		while [ "$i" -lt "$n" ]; do
			if [ "${w_repo[i]}" = "$j" ] && [ -n "${w_line[i]:-}" ]; then
				wts=$(jq -c --arg w "${w_key[i]}" --argjson e "${w_line[i]}" '.[$w] = $e' <<<"$wts")
			fi
			i=$((i + 1))
		done
		line=$(repo_entry "${r_key[j]}" "${r_target[j]}" "${r_origin[j]}" "${r_upstream[j]}" "$wts")
		PUBLISHED_REPOS=$(jq -c --argjson add "$line" '. + $add' <<<"$PUBLISHED_REPOS")
		j=$((j + 1))
	done
}

# Pushes the snapshot refs of every repo with unpushed ones. A repo that fails
# stays pending for the next run.
push_pending() {
	local rkey repo target err left=""
	[ -f "$PENDING" ] || return 0
	while IFS= read -r rkey; do
		[ -n "$rkey" ] || continue
		repo=$HOME_P/$rkey
		if [ ! -d "$repo" ]; then
			say "$rkey is gone; dropped from the push queue"
			continue
		fi
		target=$(sync_target "$repo" "$rkey")
		case $target in ignore | skip:*) continue ;; esac
		if ! err=$(git -C "$repo" push -q --force --no-verify "$(target_url "$target")" \
			"refs/srcsync/$SRCSYNC_HOST/*:refs/srcsync/$SRCSYNC_HOST/*" 2>&1); then
			say "$rkey: push failed, will retry: $(printf '%s' "$err" | grep -v '^ *$' | tail -1)"
			left=$left$rkey$'\n'
		fi
	done <"$PENDING"
	printf '%s' "$left" >"$PENDING"
	[ -z "$left" ]
}

cmd_publish() { # [repo_dir]
	local repo=${1:-} add repos doc ok=0 rkey
	ensure_last
	rm -f "$SRCSYNC_STATE/publish-failed"
	if [ -n "$repo" ]; then
		rkey=$(key_of "$repo") || return 1
		repos=$(jq -c '.repos' "$LAST")
		add=$(publish_repo "$repo")
		if [ -n "$add" ]; then
			repos=$(jq -c --argjson add "$add" '. + $add' <<<"$repos")
		else
			repos=$(jq -c --arg r "$rkey" 'del(.[$r])' <<<"$repos")
		fi
	else
		publish_all
		repos=$PUBLISHED_REPOS
	fi
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
	[ -f "$SRCSYNC_STATE/publish-failed" ] && ok=1
	[ $ok = 0 ] && now >"$LAST_SUCCESS"
	rm -f "$SRCSYNC_STATE/publish-failed"
	return $ok
}
