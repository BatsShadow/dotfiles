# Keeping the object stores srcsync writes into from growing without bound.
# See DESIGN.md "What srcsync does to a repo's objects".
#
# Every publish writes a whole new blob for each grown transcript and changed
# untracked file, and moving a srcsync ref, which keeps no reflog, leaves the
# old one unreachable. gc --auto counts loose objects, not bytes, so a few
# dozen large ones never trigger it: 100 appends to an 8.4 MB transcript took
# .git/objects from 6 MB to 605 MB.

# Loose KiB a repo needs before the timer repacks it. A big repo with nothing
# of srcsync's to collect is not rewritten every day.
REPACK_LOOSE_KB=${SRCSYNC_REPACK_LOOSE_KB:-10240}

# Repacks each repo at most once a day. -a keeps everything a ref, a reflog
# or an index reaches. The rest goes into a cruft pack, where the versions of
# one transcript delta against each other, and is dropped once it is a day
# old. A cruft pack left from before is also a reason to run, so that its
# objects do expire. The timer calls this, never the Stop hook.
repack_repos() {
	local repo rkey stamp objs kb before after
	mkdir -p "$SRCSYNC_STATE/repacked"
	while IFS= read -r repo; do
		rkey=$(key_of "$repo") || continue
		stamp=$SRCSYNC_STATE/repacked/$(printf '%s' "$rkey" | sed 's/%/%25/g; s#/#%2F#g')
		[ -n "$(find "$stamp" -mmin -1440 2>/dev/null)" ] && continue
		objs=$(git -C "$repo" rev-parse --path-format=absolute --git-path objects) || continue
		kb=$(git -C "$repo" count-objects -v | awk '/^size:/ { print $2 }')
		# only a cruft pack srcsync wrote counts; git gc writes its own
		[ "${kb:-0}" -ge "$REPACK_LOOSE_KB" ] ||
			{ [ -f "$stamp" ] && ls "$objs"/pack/*.mtimes >/dev/null 2>&1; } || continue
		before=$(du -sk "$objs" | cut -f1)
		# repack leaves an expired loose object loose; prune drops it
		if git -C "$repo" repack -q -a -d -l --cruft --cruft-expiration=1.day.ago &&
			git -C "$repo" prune --expire=1.day.ago; then
			touch "$stamp"
			after=$(du -sk "$objs" | cut -f1)
			say "$rkey: repacked, objects ${before}K to ${after}K"
		else
			say "$rkey: repack failed; next timer"
		fi
	done < <(find_repos)
}
