#!/usr/bin/env bash
# Restarting an idle Claude after an apply lays a newer transcript under it.
# A real tmux server on its own socket stands in for the panes, because
# respawn-pane -k kills whatever runs there and only real tmux shows which
# process that is. The server never sees the default socket or the real $HOME.
#
#   ./restart.test.sh

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
unset CC_PROJECTS_DIR

SOCK=srcsync-restart-$$
TM="tmux -L $SOCK"
STALE=
SOCKET_PATH=
# kill-server leaves the socket file behind
trap '$TM kill-server 2>/dev/null; [ -z "$SOCKET_PATH" ] || rm -f "$SOCKET_PATH"
	[ -z "$STALE" ] || kill "$STALE" 2>/dev/null; rm -rf "$WORK"' EXIT
export SRCSYNC_TMUX=$TM

# The fake claude-continue.sh: says how it was called and where, then stays.
MARK=$WORK/marker
cat >"$WORK/continue.sh" <<EOF
#!/bin/sh
printf '%s\n%s\n' "\$*" "\$(pwd -P)" >"$MARK"
exec sleep 1000
EOF
chmod +x "$WORK/continue.sh"
export CLAUDE_CONTINUE=$WORK/continue.sh

# A pane script that prints its lines, then leaves a child running and writes
# the child's pid, so the session's pid is a descendant of the pane's, as a
# claude under a shell is.
mkbox() { # name line...
	local n=$1 l
	shift
	{
		echo '#!/bin/sh'
		printf "printf '%%s\\\\n'"
		for l in "$@"; do printf " '%s'" "$l"; done
		echo
		echo 'sleep 1000 &'
		echo "echo \$! >\"$WORK/pid.tmp\" && mv \"$WORK/pid.tmp\" \"$WORK/pid\""
		echo 'wait'
	} >"$WORK/$n.sh"
}
R='────────────'
NBSP=$(printf '\302\240')
mkbox empty "$R" '❯ ' "$R" '  status'
mkbox typed "$R" '❯ half typed' "$R" '  status'
mkbox twoline "$R" '❯ ' '  more' "$R" '  status'
mkbox nobox 'just output' '  status'
mkbox nbsp "$R" "❯$NBSP" "$R" '  status'
# the empty box on a pty of its own inside the pane, as nvim's :terminal is
printf '#!/bin/sh\nexec script -q /dev/null sh %s/empty.sh\n' "$WORK" >"$WORK/nested.sh"

mkdir -p "$WORK/tmuxhome"
printf 'set -g default-shell /bin/sh\n' >"$WORK/tmux.conf"
HOME=$WORK/tmuxhome $TM -f "$WORK/tmux.conf" new-session -d -s t -x 80 -y 24 "sh $WORK/nobox.sh"
PANE=$($TM display-message -p -t t '#{pane_id}')
SOCKET_PATH=$($TM display-message -p '#{socket_path}')

# Respawns the pane with box $1 and waits until it shows and its pid is known.
show() { # box
	local i=0
	rm -f "$WORK/pid"
	$TM respawn-pane -k -t "$PANE" "sh $WORK/$1.sh"
	while [ $i -lt 50 ]; do
		[ -f "$WORK/pid" ] && $TM capture-pane -p -t "$PANE" | grep -q status && return 0
		i=$((i + 1))
		sleep 0.1
	done
	echo "pane never showed $1" >&2
}

# Up to 3 seconds for the marker.
marked() {
	local i=0
	while [ $i -lt 30 ]; do
		[ -s "$MARK" ] && return 0
		i=$((i + 1))
		sleep 0.1
	done
	return 1
}

printf 'input_empty\n'
empty() { lib b input_empty "$PANE" && echo yes || echo no; }
machine b
show empty
assert_eq yes "$(empty)" "an empty box is empty"
show typed
assert_eq no "$(empty)" "text after the prompt is not"
show twoline
assert_eq no "$(empty)" "nor is a second input line"
show nobox
assert_eq no "$(empty)" "nor is a pane with no box"
show nbsp
assert_eq yes "$(empty)" "a no-break space after the prompt is still empty"

machine a
echo "transcripts on" >"$(home a)/.config/srcsync/config"
echo "transcripts on" >"$(home b)/.config/srcsync/config"
github_repo app a src/app
git clone -q "$GHURL/app.git" "$(home b)/src/app" 2>/dev/null
P=$WORK/a/.claude/projects/$(printf '%s' "$WORK/a/src/app" | tr -c 'A-Za-z0-9' '-')
B=$WORK/b/.claude/projects/$(printf '%s' "$WORK/b/src/app" | tr -c 'A-Za-z0-9' '-')
mkdir -p "$P/memory"
echo '{"n":1}' >"$P/s1.jsonl"
echo remember >"$P/memory/MEMORY.md"
on a publish
on b apply
PENDING_F=$WORK/b/.local/state/srcsync/restart-pending

# An idle Claude session on b in src/app, in the pane, showing box $2.
SF=$WORK/b/.claude/sessions
idle_claude() { # name box [pid]
	rm -f "$SF"/*.json
	show "$2"
	local pid=${3:-$(cat "$WORK/pid")}
	session b idle src/app "$pid"
	jq --arg t "t:@0.$PANE" --arg n "$1" '. + {tmux: $t, name: $n}' "$SF/$pid.json" >"$SF/tmp" &&
		mv "$SF/tmp" "$SF/$pid.json"
}
# a appends to its transcript and publishes, and b applies.
grow() { # line
	rm -f "$MARK"
	: >"$WORK/b.log"
	echo "$1" >>"$P/s1.jsonl"
	on a publish
	on b apply
}

printf 'an idle Claude with an empty box\n'
idle_claude "it's app" empty
grow '{"n":2}'
assert_eq "$(cat "$P/s1.jsonl")" "$(cat "$B/s1.jsonl")" "b has the new line"
if marked; then pass "claude-continue.sh runs in the pane"; else fail "claude-continue.sh runs in the pane"; fi
assert_eq "$(printf "%s\n%s" "-n it's app" "$WORK/b/src/app")" "$(cat "$MARK" 2>&1)" \
	"with the session's name, in the worktree"
assert_eq 1 "$(grep -c "src/app: restarted the idle Claude in $PANE" "$WORK/b.log")" "and b's log says so"

printf 'an idle Claude with typed input\n'
idle_claude app typed
grow '{"n":3}'
sleep 1
[ -e "$MARK" ] && fail "the pane is left alone" || pass "the pane is left alone"
assert_eq "$WORK/b/src/app" "$(cat "$PENDING_F" 2>&1)" "restart-pending lists the worktree"
assert_eq 1 "$(grep -c "src/app: Claude has typed input; restart when it is empty" "$WORK/b.log")" \
	"and b's log says why"
idle_claude app empty
printf 'transcripts on\nauto on\n' >"$(home b)/.config/srcsync/config"
on b auto timer
if marked; then pass "auto restarts it once the box is empty"; else fail "auto restarts it once the box is empty"; fi
assert_eq "" "$(cat "$PENDING_F" 2>&1)" "and restart-pending is empty"

printf 'a pending worktree with no idle Claude left\n'
rm -f "$MARK" "$SF"/*.json
echo "$WORK/b/src/app" >"$PENDING_F"
on b auto timer
assert_eq "" "$(cat "$PENDING_F" 2>&1)" "is dropped"
sleep 1
[ -e "$MARK" ] && fail "and restarts nothing" || pass "and restarts nothing"
echo "transcripts on" >"$(home b)/.config/srcsync/config"

printf 'a busy Claude beside it\n'
idle_claude "" empty
session b busy src/app $$
grow '{"n":4}'
sleep 1
[ -e "$MARK" ] && fail "blocks the apply and the restart" || pass "blocks the apply and the restart"
assert_eq 1 "$(grep -c "src/app: Claude is working there" "$WORK/b.log")" "and b's log says so"
rm -f "$SF/$$.json"
on b apply
if marked; then pass "once it is gone, the idle one restarts"; else fail "once it is gone, the idle one restarts"; fi
assert_eq "$(printf "\n%s" "$WORK/b/src/app")" "$(cat "$MARK" 2>&1)" "with no -n when the name is empty"

printf 'a session file naming a pane its process is not in\n'
sleep 1000 &
STALE=$!
idle_claude app empty "$STALE"
BOXPID=$(cat "$WORK/pid")
grow '{"n":5}'
assert_eq "$(cat "$P/s1.jsonl")" "$(cat "$B/s1.jsonl")" "b has the new line"
sleep 1
[ -e "$MARK" ] && fail "the pane is not respawned" || pass "the pane is not respawned"
kill -0 "$BOXPID" 2>/dev/null && pass "and what runs there lives" || fail "and what runs there lives"
assert_eq "" "$(cat "$PENDING_F" 2>/dev/null)" "and nothing is pending"
kill "$STALE" 2>/dev/null
STALE=

printf 'an idle Claude in a subdirectory of the worktree\n'
idle_claude app empty
SUBPID=$(cat "$WORK/pid")
# on a, so the apply brings it; lay_tree cleans an untracked one here
mkdir -p "$WORK/a/src/app/sub"
echo sub >"$WORK/a/src/app/sub/file"
session b idle src/app/sub "$SUBPID"
jq --arg t "t:@0.$PANE" '. + {tmux: $t, name: "app"}' "$SF/$SUBPID.json" >"$SF/tmp" &&
	mv "$SF/tmp" "$SF/$SUBPID.json"
grow '{"n":6}'
assert_eq "$(cat "$P/s1.jsonl")" "$(cat "$B/s1.jsonl")" "b has the new line"
assert_eq sub "$(cat "$WORK/b/src/app/sub/file" 2>&1)" "and the subdirectory"
sleep 1
[ -e "$MARK" ] && fail "is not restarted" || pass "is not restarted"
kill -0 "$SUBPID" 2>/dev/null && pass "and what runs there lives" || fail "and what runs there lives"
assert_eq 0 "$(grep -c "restarted\|typed input" "$WORK/b.log")" "and the log says nothing of it"
assert_eq "" "$(cat "$PENDING_F" 2>/dev/null)" "and nothing is pending"

printf 'an idle Claude on a pty nested in the pane\n'
idle_claude app nested
NESTED=$(cat "$WORK/pid")
TOP=$($TM display-message -p -t "$PANE" '#{pane_pid}')
grow '{"n":7}'
assert_eq "$(cat "$P/s1.jsonl")" "$(cat "$B/s1.jsonl")" "b has the new line"
sleep 1
[ -e "$MARK" ] && fail "is not restarted" || pass "is not restarted"
kill -0 "$TOP" 2>/dev/null && kill -0 "$NESTED" 2>/dev/null && pass "and the pane's process lives" ||
	fail "and the pane's process lives"
assert_eq 0 "$(grep -c "restarted\|typed input" "$WORK/b.log")" "and the log says nothing of it"
assert_eq "" "$(cat "$PENDING_F" 2>/dev/null)" "and nothing is pending"

printf 'a pending worktree with transcripts off\n'
idle_claude app empty
rm -f "$MARK"
echo "$WORK/b/src/app" >"$PENDING_F"
echo "auto on" >"$(home b)/.config/srcsync/config"
# open on a path outside any repo: the pending retry, and nothing to publish
on b auto open "$WORK"
sleep 1
[ -e "$MARK" ] && fail "respawns nothing" || pass "respawns nothing"
echo "transcripts on" >"$(home b)/.config/srcsync/config"
: >"$PENDING_F"

printf 'an apply of code alone\n'
idle_claude app empty
rm -f "$MARK"
: >"$WORK/b.log"
echo more >>"$WORK/a/src/app/README"
on a publish
on b apply
assert_eq "$(cat "$WORK/a/src/app/README")" "$(cat "$WORK/b/src/app/README")" "b has the code"
sleep 1
[ -e "$MARK" ] && fail "restarts nothing" || pass "restarts nothing"

printf 'an apply whose lay keeps every file\n'
idle_claude app empty
rm -f "$MARK"
: >"$WORK/b.log"
echo edited >>"$P/memory/MEMORY.md"
on a publish
on b apply
assert_eq 1 "$(grep -c "src/app: took a's state" "$WORK/b.log")" "b applies"
assert_eq remember "$(cat "$B/memory/MEMORY.md")" "keeping its memory file"
assert_eq 1 "$(grep -c "src/app: kept memory/MEMORY.md" "$WORK/b.log")" "which the log says it kept"
sleep 1
[ -e "$MARK" ] && fail "and restarts nothing" || pass "and restarts nothing"

done_testing
