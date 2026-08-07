# shellcheck shell=bash
# Claude Code session status.
#
# Prints waiting/busy/idle counts across every running Claude session, and as a
# side effect stamps per-window options so window-status-format can show the
# same state without spawning a process per window. A window entering the
# waiting state also raises a macOS notification.
#
# Counts are shown from the highest-priority non-zero state rightwards, so the
# label sits against a number that means something rather than behind a run of
# zeros. At rest that is `󰚩 30·`; with something waiting it is the full
# `󰚩 1󰫢  1󰧞  30·`. No sessions at all still renders `󰚩 0·` -- this segment
# leads the right-hand status, so a vanishing one would shift everything after
# it, and a stated zero cannot be mistaken for the feature being broken.
#
# Data comes from ~/.claude/sessions/<pid>.json -- one file per live session,
# written by the CLI and removed when the session exits. Relevant fields:
#
#   {"pid":17928,"status":"idle","name":"dotfiles","kind":"interactive",
#    "waitingFor":"permission prompt", ...}
#
# status is one of idle | busy | waiting. `claude agents --json` reports the
# same thing and is the supported interface, but it costs ~290ms of node
# startup, which is far too slow for a 1s status-interval -- so it is asked
# only when a background session sits in the one state its file cannot resolve.
#
# This file holds config and rendering. The work lives in claude/:
#   collect.sh  read session files, resolve windows, emit sentinels
#   windows.sh  push state into window options, detect transitions
#   agents.sh   the blocked-agent cache
#   notify.sh   macOS notification delivery
#   goto.sh     notification click target
#   tests/      run.sh, safe to run against the live server
#
# Window options set on each window owning a claude process:
#   @cc_state  plain state name, used only to diff against the desired state
#   @cc_icon   styled glyph for normal windows
#   @cc_glyph  bare glyph for the current window, which renders inverted and
#              supplies its own foreground colour
#
# Server options:
#   @cc_primed  set once state has been populated, so a server restart does not
#               report every waiting session as a fresh transition
#   @cc_bg_amb  the ambiguous background set the blocked list was computed for

TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_DIR="${TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_DIR:-${HOME}/.claude/sessions}"
# Nerd Font glyph. It is double-width, so it must be followed by whitespace --
# with a printing character immediately after it the terminal clips it into one
# cell and it renders low and squashed. The two spaces below are load-bearing.
TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_LABEL="${TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_LABEL:-󰚩}"

# Label heading a notification, which is a different problem from the label on
# the bar. The glyph above is in the Nerd Font private use area -- that font is
# installed in the terminal, but Notification Center renders with the system
# font, so the glyph arrives there as a tofu box in front of the window name.
# Plain text is the only thing that reads correctly in both places. Empty is
# honoured, and drops the label from the title entirely.
TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_NOTIFY_LABEL="${TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_NOTIFY_LABEL-Claude}"

# Only the waiting state is chromatic. Everything else is a luminance ramp, so
# at rest the segment is pure greyscale and colour on the bar always means
# "something needs you".
TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_WAIT_COLOR="${TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_WAIT_COLOR:-#e6b450}"
TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_BUSY_COLOR="${TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_BUSY_COLOR:-#acb6bf}"
TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_IDLE_COLOR="${TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_IDLE_COLOR:-#565b66}"

# Sized to read at a glance rather than to pack tightly -- if a count ends up
# touching its glyph, widen TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_GAP below rather
# than shrinking these.
TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_WAIT_GLYPH="${TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_WAIT_GLYPH:-󰫢}"
TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_BUSY_GLYPH="${TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_BUSY_GLYPH:-󰧞}"
TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_IDLE_GLYPH="${TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_IDLE_GLYPH:-·}"

# Glyph marking an idle window in the window list, as opposed to the idle count
# in the segment above. Empty: idle is the resting state of most windows, so
# marking it is noise, and an empty value leaves the window label untouched.
# Set it to the same value as IDLE_GLYPH to mark idle windows again.
TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_WIN_IDLE_GLYPH="${TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_WIN_IDLE_GLYPH-}"

# A background agent blocked on input is recorded as "idle" in its session
# file -- the file's status vocabulary has no value for it. The only place
# that condition appears is `claude agents --json`, which costs ~290ms and so
# cannot sit on the status-interval path. It is asked only when a background
# session enters the ambiguous idle state; see claude/agents.sh.
TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_AGENTS_CMD="${TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_AGENTS_CMD:-claude}"
# Backstop only, not the primary trigger: the longest an answer may stand
# before being asked again, and only while something is actually ambiguous.
TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_AGENTS_TTL="${TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_AGENTS_TTL:-60}"

# Normal fill colour of the current-window bubble, and normal window-label
# text colour. The theme exports its own values so these cannot drift apart.
TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_CUR_BG="${TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_CUR_BG:-#59c2ff}"
TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_TEXT_FG="${TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_TEXT_FG:-#bfbdb6}"

# Separator between a count and its glyph. Empty by default because the glyphs
# above carry their own bearing. Set it to a space (or U+2009/U+200A, if your
# font gives them a narrow cell) to push the two further apart.
TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_GAP="${TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_GAP-}"

# Space between the label and the first count.
TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_LABEL_GAP="${TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_LABEL_GAP- }"

# Space between a window name and its status glyph, in the window list. Lives
# inside the option value so the window format needs no conditional.
TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_WIN_GAP="${TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_WIN_GAP-}"

# Notification delivery. Empty means auto-detect: terminal-notifier if it is
# installed, otherwise osascript. Set it to a command to override, which is how
# the test suite captures notifications.
TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_NOTIFY_CMD="${TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_NOTIFY_CMD-}"
# Application raised when a notification is clicked.
TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_TERM_APP="${TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_TERM_APP:-WezTerm}"

# Helpers live in a subdirectory rather than beside this file. tmux-powerline
# sources every *.sh in its own segments directory when generating a default
# config (lib/config_file.sh) and resolves segments by bare name
# (lib/powerline.sh), and neither path recurses -- so nothing here can be
# mistaken for a segment.
#
# A missing helper degrades to a quiet segment rather than an error in the
# status bar, which is why each source is guarded rather than assumed.
__cc_helpers="${BASH_SOURCE[0]%/*}/claude"
for __cc_helper in collect windows agents notify; do
	if [ -r "${__cc_helpers}/${__cc_helper}.sh" ]; then
		# shellcheck disable=SC1090
		source "${__cc_helpers}/${__cc_helper}.sh"
	fi
done
unset __cc_helper __cc_helpers

generate_segmentrc() {
	read -r -d '' rccontents <<EORC
# Directory holding one JSON status file per live Claude session.
export TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_DIR="${TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_DIR}"
# Label shown before the counts.
export TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_LABEL="${TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_LABEL}"
# Label heading a notification. Plain text, not the glyph above: Notification
# Center renders with the system font, which has no Nerd Font glyphs.
export TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_NOTIFY_LABEL="${TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_NOTIFY_LABEL}"
# Colours per state. Keep waiting as the only saturated one.
export TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_WAIT_COLOR="${TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_WAIT_COLOR}"
export TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_BUSY_COLOR="${TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_BUSY_COLOR}"
export TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_IDLE_COLOR="${TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_IDLE_COLOR}"
# Glyphs per state.
export TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_WAIT_GLYPH="${TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_WAIT_GLYPH}"
export TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_BUSY_GLYPH="${TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_BUSY_GLYPH}"
export TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_IDLE_GLYPH="${TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_IDLE_GLYPH}"
export TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_WIN_IDLE_GLYPH="${TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_WIN_IDLE_GLYPH}"
# Blocked background agents: how to ask, and the backstop interval that bounds
# how stale an answer may get while something is ambiguous.
export TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_AGENTS_CMD="${TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_AGENTS_CMD}"
export TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_AGENTS_TTL="${TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_AGENTS_TTL}"
# Spacing. Each is inserted verbatim, so a space means one cell.
export TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_GAP="${TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_GAP}"
export TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_LABEL_GAP="${TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_LABEL_GAP}"
export TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_WIN_GAP="${TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_WIN_GAP}"
# Notification delivery. Empty auto-detects terminal-notifier, then osascript.
export TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_NOTIFY_CMD="${TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_NOTIFY_CMD}"
# Application raised when a notification is clicked.
export TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_TERM_APP="${TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_TERM_APP}"
EORC
	echo "$rccontents"
}

run_segment() {
	local dir="$TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_DIR"
	[ -d "$dir" ] || return 0
	command -v jq >/dev/null 2>&1 || return 0

	# Last good frame, replayed when a read fails so the segment holds its
	# content rather than blanking for a tick.
	local cache="${TMPDIR:-/tmp}/tmux-powerline-claude-sessions.${UID}.cache"

	# Before anything else, and regardless of whether there are sessions: a
	# window with no colours is a rendering bug, not a missing status.
	__cc_ensure_globals

	local blocked="${TMPDIR:-/tmp}/tmux-powerline-claude-blocked.${UID}.list"

	local raw
	raw=$(__cc_collect "$dir" "$blocked")

	if [ -z "$raw" ]; then
		[ -s "$cache" ] && cat "$cache"
		return 0
	fi

	# A failed parse, not an empty directory. Show the last good frame and leave
	# every window option exactly as it is: clearing @cc_state here would make
	# the next tick read every waiting window as a fresh transition and notify
	# on all of them. Skipping the sync delays a transition by a tick; clearing
	# state would invent one.
	if [ "$raw" = "TORN" ]; then
		[ -s "$cache" ] && cat "$cache"
		return 0
	fi

	# desired_pid maps window to the pid of the session that won it. Sync does
	# not read it -- it is threaded through for the notification path, which
	# needs a pid to resolve waitingFor for a transition.
	local -A desired=() desired_pid=()
	local -a transitions=()
	# a b c are the read fields of the parse loop below. Undeclared they would
	# leak into every sibling segment, same as any other name here.
	local waiting=0 busy=0 idle=0 kind window state a b c

	# EMPTY needs no branch of its own. The three counts are already zero, the
	# parse loop below matches only COUNTS and WIN so the bare sentinel falls
	# through untouched, and an empty `desired` is what makes the sync strip
	# every window icon. The render block then states the zero rather than
	# blanking the segment, and tee overwrites the stale frame in the cache.
	local amb=""
	while read -r kind a b c; do
		case "$kind" in
		COUNTS)
			waiting="$a"
			busy="$b"
			idle="$c"
			;;
		WIN)
			window="$a"
			state="$b"
			desired["$window"]="$state"
			desired_pid["$window"]="$c"
			;;
		AMB)
			amb="${amb}${amb:+ }${a}"
			;;
		esac
	done <<<"$raw"

	# awk emits array keys in no particular order, so sort before comparing --
	# an unsorted fingerprint would appear to change on its own and re-ask the
	# binary for a set that had not actually moved. Guarded because an empty set
	# is the steady state, and sorting nothing still costs a sort and a tr on
	# every single tick.
	if [ -n "$amb" ]; then
		# Deliberately unquoted: the words are the set.
		# shellcheck disable=SC2086
		amb=$(printf '%s\n' $amb | sort -n | tr '\n' ' ')
		amb="${amb% }"
	fi

	# Kicked after collect rather than before it: the trigger is derived from
	# this tick's session files, and the answer lands for the next one.
	__cc_refresh_blocked "$blocked" "$amb"

	__cc_sync_windows desired transitions

	# After the sync, never before: by this point @cc_state already reads
	# waiting, so a concurrently running copy of the segment sees no transition
	# and cannot deliver a duplicate.
	__cc_notify "$dir" transitions desired_pid

	local segfg="${TMUX_POWERLINE_CUR_SEGMENT_FG:-$TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_IDLE_COLOR}"
	local wait_color="$TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_IDLE_COLOR"
	local wait_attr=""

	# Only light up once something is actually waiting, so the resting bar has
	# no colour anywhere and the eye has nothing to catch on.
	if [ "$waiting" -gt 0 ]; then
		wait_color="$TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_WAIT_COLOR"
		wait_attr=",bold"
	fi

	# Same rule for busy: a zero count is not news, so it drops to the idle
	# grey and only the counts that are actually non-zero carry any weight.
	local busy_color="$TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_IDLE_COLOR"
	[ "$busy" -gt 0 ] && busy_color="$TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_BUSY_COLOR"

	# The label carries the most demanding state present, so the segment reads
	# at a glance without parsing the numbers: amber means something is waiting
	# on you, whatever the counts say. Grey only when everything is idle.
	local label_color="$TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_IDLE_COLOR"
	if [ "$waiting" -gt 0 ]; then
		label_color="$TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_WAIT_COLOR"
	elif [ "$busy" -gt 0 ]; then
		label_color="$TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_BUSY_COLOR"
	fi

	local gap="$TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_GAP"

	local out=""
	# The label is single-width under Monaspace NF -- same advance as any other
	# character -- so one space is enough to keep it from reading as part of
	# the first number.
	local lgap="$TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_LABEL_GAP"
	out+="#[fg=${label_color}]${TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_LABEL}${lgap}"

	# Show the groups from the highest-priority non-zero state rightwards, so at
	# rest the label abuts the only count that says anything instead of two
	# zeros. Interior and trailing zeros stay: a zero busy beside a non-zero
	# waiting is news, since it means nothing is in flight to resolve those
	# waiting sessions on its own. Idle is always present, which is what makes
	# no sessions at all read as a stated `0` rather than an absent segment --
	# and an absent segment would shift the whole right-hand block of the bar.
	#
	# Deliberately the same priority order that picks the label colour above, so
	# the label and the count it touches can never disagree about which state
	# they are describing.
	local -a groups=()
	if [ "$waiting" -gt 0 ]; then
		groups+=("#[fg=${wait_color}${wait_attr}]${waiting}${gap}${TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_WAIT_GLYPH}")
	fi
	if [ "$waiting" -gt 0 ] || [ "$busy" -gt 0 ]; then
		groups+=("#[fg=${busy_color}]${busy}${gap}${TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_BUSY_GLYPH}")
	fi
	groups+=("#[fg=${TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_IDLE_COLOR}]${idle}${gap}${TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_IDLE_GLYPH}")

	# All the counts are spaced identically -- the glyphs do the separating, so
	# the gap is empty and the groups stay visually even. The nobold rides on
	# every separator rather than just the first: the bold belongs to the waiting
	# group, and the waiting group is precisely the one that can disappear.
	local sep="#[fg=${segfg},nobold]  " joined="" g
	for g in "${groups[@]}"; do
		joined+="${joined:+$sep}${g}"
	done
	out+="$joined"
	out+="#[fg=${segfg},nobold]"

	printf '%s' "$out" | tee "$cache"
	return 0
}
