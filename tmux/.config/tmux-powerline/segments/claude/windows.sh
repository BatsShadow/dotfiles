# shellcheck shell=bash

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
