# shellcheck shell=bash
# Claude Code session status.
#
# Prints waiting/busy/idle counts across every running Claude session, and as a
# side effect stamps per-window options so window-status-format can show the
# same state without spawning a process per window.
#
# Data comes from ~/.claude/sessions/<pid>.json — one file per live session,
# written by the CLI and removed when the session exits. Relevant fields:
#
#   {"pid":17928,"status":"idle","name":"dotfiles","kind":"interactive",
#    "waitingFor":"permission prompt", ...}
#
# status is one of idle | busy | waiting. `claude agents --json` reports the
# same thing and is the supported interface, but it costs ~290ms of node
# startup, which is far too slow for a 1s status-interval.
#
# Window options set on each window owning a claude process:
#   @cc_state  plain state name, used only to diff against the desired state
#   @cc_icon   styled glyph for normal windows
#   @cc_glyph  bare glyph for the current window, which renders inverted and
#              supplies its own foreground colour

TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_DIR="${TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_DIR:-${HOME}/.claude/sessions}"
# Nerd Font glyph. It is double-width, so it must be followed by whitespace --
# with a printing character immediately after it the terminal clips it into one
# cell and it renders low and squashed. The two spaces below are load-bearing.
TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_LABEL="${TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_LABEL:-󰚩}"

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

generate_segmentrc() {
	read -r -d '' rccontents <<EORC
# Directory holding one JSON status file per live Claude session.
export TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_DIR="${TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_DIR}"
# Label shown before the counts.
export TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_LABEL="${TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_LABEL}"
# Colours per state. Keep waiting as the only saturated one.
export TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_WAIT_COLOR="${TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_WAIT_COLOR}"
export TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_BUSY_COLOR="${TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_BUSY_COLOR}"
export TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_IDLE_COLOR="${TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_IDLE_COLOR}"
# Glyphs per state.
export TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_WAIT_GLYPH="${TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_WAIT_GLYPH}"
export TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_BUSY_GLYPH="${TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_BUSY_GLYPH}"
export TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_IDLE_GLYPH="${TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_IDLE_GLYPH}"
export TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_WIN_IDLE_GLYPH="${TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_WIN_IDLE_GLYPH}"
# Spacing. Each is inserted verbatim, so a space means one cell.
export TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_GAP="${TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_GAP}"
export TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_LABEL_GAP="${TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_LABEL_GAP}"
export TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_WIN_GAP="${TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_WIN_GAP}"
EORC
	echo "$rccontents"
}

# Plant the default bubble fill and label colour as GLOBAL options.
#
# tmux resolves a user option window -> session -> global, so a window that
# this script has never touched still renders with the right colours. Without
# them a newly created window expands #{@cc_cur_bg} to nothing, the format
# becomes "#[fg=,bg=...]", tmux discards the whole style, and the window flashes
# unstyled until the next segment run picks it up.
#
# show-options -gv errors on an option that does not exist yet -- precisely the
# case being fixed -- so read the full listing, which always succeeds.
__cc_ensure_globals() {
	local want_bg="$TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_CUR_BG"
	local want_fg="$TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_TEXT_FG"
	local got_bg="" got_fg="" line value

	while IFS= read -r line; do
		case "$line" in
		'@cc_cur_bg '*) value="${line#@cc_cur_bg }" ;;
		'@cc_fg '*) value="${line#@cc_fg }" ;;
		*) continue ;;
		esac
		# show-options quotes values; the colours start with '#' so they always
		# come back quoted.
		value="${value#\"}"
		value="${value%\"}"
		case "$line" in
		'@cc_cur_bg '*) got_bg="$value" ;;
		*) got_fg="$value" ;;
		esac
	done < <(tmux show-options -g 2>/dev/null)

	local cmds=()
	[ "$got_bg" != "$want_bg" ] && cmds+=(set-option -g @cc_cur_bg "$want_bg")
	if [ "$got_fg" != "$want_fg" ]; then
		[ ${#cmds[@]} -gt 0 ] && cmds+=(";")
		cmds+=(set-option -g @cc_fg "$want_fg")
	fi
	[ ${#cmds[@]} -gt 0 ] && tmux "${cmds[@]}" 2>/dev/null

	return 0
}

# Resolve each session's pid up its process tree until it reaches a pane, so a
# session is attributed to the window that actually owns it. Matching on the
# session `name` instead would be wrong: two sessions can share a name (there
# are currently two called fp-wallet-avs) and background agents have no window.
__cc_collect() {
	local dir="$1"
	{
		echo "P"
		ps -eo pid=,ppid=
		echo "W"
		tmux list-panes -a -F '#{pane_pid} #{session_name}:#{window_index}'
		echo "S"
		cat "$dir"/*.json 2>/dev/null | jq -r -n '
			[inputs]
			| .[]
			| select(.pid != null and .status != null)
			| [(.pid | tostring), .status, (.kind // "-"),
			   (.jobId // "-"), (.parkedJobId // "-")]
			| @tsv' 2>/dev/null
	} | awk '
		$0 == "P" { mode = "P"; next }
		$0 == "W" { mode = "W"; next }
		$0 == "S" { mode = "S"; next }
		mode == "P" { parent[$1] = $2; next }
		mode == "W" { pane[$1] = $2; next }
		# Buffer the sessions rather than resolving inline: a background agent
		# can be read before the interactive session that parked it.
		mode == "S" {
			n++
			spid[n] = $1; sstatus[n] = $2; skind[n] = $3; sjob[n] = $4
			if ($5 != "-") parked[$5] = $1

			if ($2 == "waiting")   waiting++
			else if ($2 == "busy") busy++
			else                   idle++
		}
		END {
			if (!n) { print "EMPTY"; exit }
			printf "COUNTS %d %d %d\n", waiting + 0, busy + 0, idle + 0

			for (s = 1; s <= n; s++) {
				p = spid[s]

				# A background agent has no pane of its own — it is spawned
				# under the daemon, not under a shell. Its work still belongs
				# to the window whose session parked it, which is the window
				# the user is actually looking at, so borrow that pid and
				# resolve from there. Without this the window shows the idle
				# state of the parked session while the real work happens
				# invisibly. Note the awk body is single-quoted, so no
				# apostrophes in these comments.
				if (skind[s] == "bg" && sjob[s] != "-" && (sjob[s] in parked))
					p = parked[sjob[s]]

				rank = (sstatus[s] == "waiting" ? 3 : (sstatus[s] == "busy" ? 2 : 1))

				# Walk up to the owning pane. Bounded so a cycle or a
				# reparented process can never spin.
				for (i = 0; i < 24; i++) {
					if (p == "" || p == "0" || p == "1") break
					if (p in pane) {
						w = pane[p]
						# A window can hold more than one session — including a
						# parked one plus its background agent. Most demanding
						# state wins.
						if (rank > best[w]) { best[w] = rank; state[w] = sstatus[s] }
						break
					}
					p = parent[p]
				}
			}

			for (w in state) printf "WIN %s %s\n", w, state[w]
		}
	'
}

# Push @cc_* onto windows that changed, and strip them from windows that no
# longer host a session. Writing unconditionally would make tmux redraw the
# status line every second, so only genuine transitions produce a tmux call.
__cc_sync_windows() {
	# Prefixed to avoid a circular nameref if the caller's variable shares the
	# name, which silently resolves the map to empty.
	local -n __cc_desired=$1
	local current window state curbg cmds=() first=1

	# Every window, not just the Claude ones: the current-window bubble colour
	# has to be reset on windows that stop waiting too, so all of them need to
	# be considered.
	#
	# The separator must not be whitespace. Bash collapses *runs* of IFS
	# whitespace into one delimiter, so with tabs an unset option silently
	# disappears and every later field shifts left -- a window with no state
	# then parses its colour as its state, which makes every window look
	# changed and rewrites the lot every second. A control byte is no good
	# either: tmux escapes 0x1f into a literal backslash-zero-three-seven.
	current=$(tmux list-windows -a -F \
		'#{session_name}:#{window_index}|#{@cc_state}|#{@cc_cur_bg}|#{@cc_fg}|#{@cc_icon}' 2>/dev/null)

	local -A have=() have_bg=() have_fg=() have_icon=() all=()
	while IFS='|' read -r window state curbg fg icon; do
		[ -n "$window" ] || continue
		all["$window"]=1
		[ -n "$state" ] && have["$window"]="$state"
		have_bg["$window"]="$curbg"
		have_fg["$window"]="$fg"
		have_icon["$window"]="$icon"
	done <<<"$current"

	for window in "${!all[@]}"; do
		# tmux rejects an over-long command sequence outright with "command too
		# long" and applies none of it, so flush in chunks instead of building
		# one giant batch. Only a first build or a config change gets anywhere
		# near this; the steady state sends nothing at all.
		if [ ${#cmds[@]} -ge 120 ]; then
			tmux "${cmds[@]}" 2>/dev/null
			cmds=()
			first=1
		fi

		state="${__cc_desired[$window]-}"

		# The current window renders as a filled bubble, and amber text on that
		# cyan fill is near-invisible since both are light. Recolouring the
		# bubble itself is the only treatment that stays legible there.
		local want_bg="$TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_CUR_BG"
		# On a non-current window there is no fill to recolour, so the whole
		# label goes amber instead of just the glyph. Busy and idle leave the
		# text alone and let the glyph carry the state on its own.
		local want_fg="$TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_TEXT_FG"
		if [ "$state" = "waiting" ]; then
			want_bg="$TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_WAIT_COLOR"
			want_fg="$TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_WAIT_COLOR"
		fi

		# When the wanted value is just the default, clear the window-level
		# option rather than writing the default into it. The window then
		# inherits the global, which is what lets a brand new window render
		# correctly before this script has ever seen it.
		if [ "${have_bg[$window]-}" != "$want_bg" ]; then
			[ $first -eq 1 ] && first=0 || cmds+=(";")
			if [ "$want_bg" = "$TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_CUR_BG" ]; then
				cmds+=(set-option -w -t "$window" -u @cc_cur_bg)
			else
				cmds+=(set-option -w -t "$window" @cc_cur_bg "$want_bg")
			fi
		fi

		if [ "${have_fg[$window]-}" != "$want_fg" ]; then
			[ $first -eq 1 ] && first=0 || cmds+=(";")
			if [ "$want_fg" = "$TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_TEXT_FG" ]; then
				cmds+=(set-option -w -t "$window" -u @cc_fg)
			else
				cmds+=(set-option -w -t "$window" @cc_fg "$want_fg")
			fi
		fi

		if [ -z "$state" ]; then
			[ -z "${have[$window]-}" ] && continue
			[ $first -eq 1 ] && first=0 || cmds+=(";")
			cmds+=(set-option -w -t "$window" -u @cc_state ";")
			cmds+=(set-option -w -t "$window" -u @cc_glyph ";")
			cmds+=(set-option -w -t "$window" -u @cc_icon)
			continue
		fi

		local glyph color
		case "$state" in
		waiting)
			glyph="$TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_WAIT_GLYPH"
			color="$TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_WAIT_COLOR"
			;;
		busy)
			glyph="$TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_BUSY_GLYPH"
			color="$TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_BUSY_COLOR"
			;;
		*)
			glyph="$TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_WIN_IDLE_GLYPH"
			color="$TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_IDLE_COLOR"
			;;
		esac

		# The separator lives inside the option value so the window format
		# needs no conditional: an unset option then contributes nothing at
		# all, spacing included. An empty glyph means the state is not worth
		# marking, so the options are cleared rather than set to a style with
		# nothing after it.
		local wg="$TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_WIN_GAP"
		local want_icon="" want_glyph=""
		if [ -n "$glyph" ]; then
			want_icon="#[fg=${color}]${wg}${glyph}"
			want_glyph="${wg}${glyph}"
		fi

		# Diff on the rendered value, not on the state name. Diffing on state
		# would leave every window holding a stale glyph or colour after a
		# config change, since the state has not moved.
		[ "${have_icon[$window]-}" = "$want_icon" ] && continue

		[ $first -eq 1 ] && first=0 || cmds+=(";")
		cmds+=(set-option -w -t "$window" @cc_state "$state" ";")
		if [ -z "$want_icon" ]; then
			cmds+=(set-option -w -t "$window" -u @cc_glyph ";")
			cmds+=(set-option -w -t "$window" -u @cc_icon)
		else
			cmds+=(set-option -w -t "$window" @cc_glyph "$want_glyph" ";")
			cmds+=(set-option -w -t "$window" @cc_icon "$want_icon")
		fi
	done

	[ ${#cmds[@]} -gt 0 ] && tmux "${cmds[@]}" 2>/dev/null
	return 0
}

run_segment() {
	local dir="$TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_DIR"
	[ -d "$dir" ] || return 0
	command -v jq >/dev/null 2>&1 || return 0

	# Surviving a torn read matters more than the 20ms it costs: a status file
	# caught mid-write aborts jq, and blanking the segment for one tick out of
	# every few hundred reads as a flicker at a 1s refresh.
	local cache="${TMPDIR:-/tmp}/tmux-powerline-claude-sessions.${UID}.cache"

	# Before anything else, and regardless of whether there are sessions: a
	# window with no colours is a rendering bug, not a missing status.
	__cc_ensure_globals

	local raw
	raw=$(__cc_collect "$dir")

	if [ -z "$raw" ]; then
		[ -s "$cache" ] && cat "$cache"
		return 0
	fi

	local -A desired=()
	local waiting=0 busy=0 idle=0 kind window state

	if [ "$raw" = "EMPTY" ]; then
		# Genuinely no sessions — drop the stale frame rather than showing it
		# forever, and strip every window icon.
		rm -f "$cache"
		__cc_sync_windows desired
		return 0
	fi

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
			;;
		esac
	done <<<"$raw"

	__cc_sync_windows desired

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

	local gap="$TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_GAP"

	local out=""
	# The label is single-width under Monaspace NF -- same advance as any other
	# character -- so one space is enough to keep it from reading as part of
	# the first number.
	local lgap="$TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_LABEL_GAP"
	out+="#[fg=${TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_IDLE_COLOR}]${TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_LABEL}${lgap}"
	# All three counts are spaced identically -- the glyphs do the separating,
	# so the gap is empty and the groups stay visually even.
	out+="#[fg=${wait_color}${wait_attr}]${waiting}${gap}${TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_WAIT_GLYPH}"
	out+="#[fg=${segfg},nobold]  "
	out+="#[fg=${busy_color}]${busy}${gap}${TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_BUSY_GLYPH}"
	out+="#[fg=${segfg}]  "
	out+="#[fg=${TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_IDLE_COLOR}]${idle}${gap}${TMUX_POWERLINE_SEG_CLAUDE_SESSIONS_IDLE_GLYPH}"
	out+="#[fg=${segfg}]"

	printf '%s' "$out" | tee "$cache"
	return 0
}
