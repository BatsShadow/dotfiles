# auto: the one entry point every trigger calls, Claude hooks, the launchd
# timer, sleep/wake, the tmux sessionizer. Off, the default, it only logs what
# it would run, so wiring up a trigger is harmless until the config says
# `auto on`. AUTO_LOG keeps its last 2000 lines so nothing grows forever.

AUTO_LOG=$SRCSYNC_STATE/auto.log

# Off runs are unlocked and can trim at once. A shared tmp name emptied the
# log; a tmp per call can only lose lines.
trim_auto_log() {
	[ -f "$AUTO_LOG" ] || return 0
	local tmp
	tmp=$(mktemp "$AUTO_LOG.XXXXXX") || return 1
	if tail -n 2000 "$AUTO_LOG" >"$tmp"; then
		mv "$tmp" "$AUTO_LOG"
	else
		rm -f "$tmp"
		return 1
	fi
}

# With a path, the worktree that holds it, which is what Claude's hooks
# pass: they publish only the worktree the turn ran in.
auto_publish() { # path
	local scoped
	if [ -z "$1" ]; then
		cmd_publish
	elif scoped=$(resolve_path "$1"); then
		cmd_publish "${scoped%%$'\t'*}" "${scoped#*$'\t'}"
	else
		say "$1: not a synced repo"
	fi
}

# The worktree half of resolve_path, as the plain apply takes it.
auto_apply() { # path
	local scoped
	if [ -z "$1" ]; then
		cmd_apply
	elif scoped=$(resolve_path "$1"); then
		cmd_apply "${scoped#*$'\t'}"
	else
		say "$1: not a synced repo"
	fi
}

# sleep waits up to 20 seconds for the lock, one-second retries: it is the
# last chance to publish before the lid closes. Every other event gives up at
# once, like the plain commands.
auto_lock() { # event
	local i=0
	[ "$1" = sleep ] || { take_lock; return; }
	while ! take_lock; do
		i=$((i + 1))
		[ "$i" -lt 20 ] || return 1
		sleep 1
	done
}

# A turn that ended while another run held the lock: the holder publishes
# its worktree before it writes the hub, rather than the next timer run. One
# file per hook, renamed into place whole, so the holder can never read half
# of one or delete one it has not read.
want() { # event path
	local scoped wt d=$SRCSYNC_STATE/wanted.d tmp
	case $1 in stop | end) ;; *) return 0 ;; esac
	scoped=$(resolve_path "$2") || return 0
	wt=${scoped#*$'\t'}
	mkdir -p "$d"
	grep -qxF "$wt" "$d"/* 2>/dev/null && return 0
	tmp=$(mktemp "$d/.new.XXXXXX") || return 0
	if printf '%s\n' "$wt" >"$tmp" && mv "$tmp" "$d/$(date +%s).$$"; then
		say "queued $wt for the run holding the lock"
	else
		rm -f "$tmp"
	fi
}

# Runs the command an event maps to.
auto_run() { # event path
	case $1 in
	timer)
		cmd_publish
		cmd_apply
		repack_repos
		;;
	stop | end) auto_publish "$2" ;;
	sleep) auto_publish "" ;;
	wake) auto_apply "" ;;
	open) auto_apply "$2" ;;
	esac
}

cmd_auto() { # event [path]
	local event=${1:-} path=${2:-} label=${2:--} desc
	case $event in
	timer) desc=sync ;;
	stop | end) desc="publish${path:+ $path}" ;;
	sleep) desc=publish ;;
	wake) desc=apply ;;
	open) desc="apply${path:+ $path}" ;;
	*)
		echo "usage: srcsync.sh auto timer|stop|end|sleep|wake|open [path]" >&2
		return 2
		;;
	esac

	mkdir -p "$SRCSYNC_STATE"
	if [ "$CFG_AUTO" != on ]; then
		printf '%s dry %s %s would run %s\n' "$(now)" "$event" "$label" "$desc" >>"$AUTO_LOG"
		trim_auto_log
		return 0
	fi

	printf '%s %s %s\n' "$(now)" "$event" "$label" >>"$AUTO_LOG"
	{
		if auto_lock "$event"; then
			# first, so an apply below that finds typed input says so once
			restart_pending
			auto_run "$event" "$path"
			# a turn that ended while this run applied or repacked
			wanted_waiting && cmd_publish_queue
		else
			say "another run holds the lock"
			want "$event" "$path"
		fi
	} >>"$AUTO_LOG" 2>&1
	trim_auto_log
	return 0
}
