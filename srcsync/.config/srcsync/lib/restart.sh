# Restarting an idle Claude after an apply lays a newer transcript under it.
# An idle Claude keeps the conversation it loaded and never rereads the file,
# so typing into it would fork the transcript. claude-continue.sh's claude -c
# loads the newest one. See DESIGN.md "The idle Claude holding an old
# conversation".
#
# respawn-pane -k kills whatever runs in the pane, so a pane is only touched
# when a live idle session names it, the session's process runs in it, and its
# input box is empty just before the respawn.

CLAUDE_CONTINUE=${CLAUDE_CONTINUE:-$HOME/.config/tmux/claude-continue.sh}
RESTART_PENDING=$SRCSYNC_STATE/restart-pending

# Split on spaces, so tests can pass tmux -L <socket>.
tm() {
	${SRCSYNC_TMUX:-tmux} "$@"
}

# True when process $2 owns pane $1: it descends from the pane's process, sits
# on the pane's own tty, and is in that tty's foreground process group. A
# session file outlives a crash, and after a tmux restart its pane id can name
# some other pane. A descendant on another pty, like a Claude in nvim's
# :terminal or under script, would take its host down with the respawn.
pane_runs() { # pane pid
	local top tty p=$2 i=0 ptty tpgid pgid
	IFS=' ' read -r top tty < <(tm display-message -p -t "$1" '#{pane_pid} #{pane_tty}' 2>/dev/null)
	[ -n "$top" ] && [ -n "$tty" ] || return 1
	read -r ptty tpgid pgid < <(ps -o tty=,tpgid=,pgid= -p "$2" 2>/dev/null)
	[ "/dev/$ptty" = "$tty" ] && [ -n "$pgid" ] && [ "$tpgid" = "$pgid" ] || return 1
	while [ "$i" -lt 64 ] && [ -n "$p" ] && [ "$p" -gt 1 ]; do
		[ "$p" = "$top" ] && return 0
		p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
		i=$((i + 1))
	done
	return 1
}

# pane_id, pid and name, tab-separated, of each live idle Claude in $1 itself
# whose process runs in the tmux pane its session file names. One in a
# subdirectory is left alone: its transcripts sit under that directory's slug,
# which srcsync does not carry, and a restart in $1 would switch its
# conversation. The name goes last since it can be empty, and read collapses
# empty tab fields.
idle_panes() { # wt
	local f pid tmux cwd name wt_p
	wt_p=$(cd "$1" 2>/dev/null && pwd -P) || return 0
	for f in "$CC_SESSIONS_DIR"/*.json; do
		[ -f "$f" ] || continue
		IFS=$'\t' read -r pid tmux cwd name < <(jq -r '
			select(.status == "idle" and (.tmux // "") != "" and (.cwd // "") != "")
			| [.pid, .tmux, .cwd, .name // ""] | @tsv' "$f" 2>/dev/null)
		[ -n "$pid" ] && [ -n "$tmux" ] || continue
		[ "$(cd "$cwd" 2>/dev/null && pwd -P)" = "$wt_p" ] || continue
		kill -0 "$pid" 2>/dev/null || continue
		pane_runs "${tmux##*.}" "$pid" || continue
		printf '%s\t%s\t%s\n' "${tmux##*.}" "$pid" "$name"
	done
}

# True when pane $1's Claude input box holds nothing: exactly one line between
# the last two rules of ─, and that line is ❯ and whitespace. Anything else,
# no box included, reads as typed input, since a restart would lose it.
input_empty() { # pane
	local screen l n=0 a=-1 b=-1 i lines=()
	screen=$(tm capture-pane -p -t "$1" 2>/dev/null) || return 1
	while IFS= read -r l; do
		lines+=("$l")
		l=${l%"${l##*[![:space:]]}"}
		if [ -n "$l" ] && [ -z "${l//─/}" ]; then
			a=$b
			b=$n
		fi
		n=$((n + 1))
	done <<<"$screen"
	[ "$a" -ge 0 ] && [ $((b - a)) -eq 2 ] || return 1
	i=$((a + 1))
	l=${lines[$i]}
	[ "${l#❯}" != "$l" ] || return 1
	l=${l#❯}
	l=${l//$'\302\240'/}
	l=${l//[[:space:]]/}
	[ -z "$l" ]
}

# Respawns each idle Claude in $1 whose box is empty, and puts the
# worktree on the pending list when any has typed input.
restart_idle() { # wt
	local pane pid name key cmd typed=
	key=$(key_of "$1" 2>/dev/null) || key=$1
	while IFS=$'\t' read -r pane pid name; do
		pane_runs "$pane" "$pid" || continue
		if input_empty "$pane"; then
			cmd="'$(sq "$CLAUDE_CONTINUE")'"
			[ -z "$name" ] || cmd="$cmd -n '$(sq "$name")'"
			tm respawn-pane -k -t "$pane" -c "$1" "$cmd; exec zsh -l" &&
				say "$key: restarted the idle Claude in $pane"
		else
			typed=1
		fi
	done < <(idle_panes "$1")
	[ -n "$typed" ] || return 0
	grep -qxF "$1" "$RESTART_PENDING" 2>/dev/null || echo "$1" >>"$RESTART_PENDING"
	say "$key: Claude has typed input; restart when it is empty"
}

# $1 with each ' closed, escaped and reopened, for a single-quoted shell word.
sq() {
	printf '%s' "$1" | sed "s/'/'\\\\''/g"
}

# Retries every pending worktree. One still typed goes back on the list; one
# with no idle Claude left drops off.
restart_pending() {
	local wts=() wt
	# a list left from transcripts on must not respawn anything once off
	[ "$CFG_TRANSCRIPTS" = on ] || return 0
	[ -s "$RESTART_PENDING" ] || return 0
	while IFS= read -r wt; do [ -n "$wt" ] && wts+=("$wt"); done <"$RESTART_PENDING"
	: >"$RESTART_PENDING"
	for wt in ${wts[@]+"${wts[@]}"}; do restart_idle "$wt"; done
}
