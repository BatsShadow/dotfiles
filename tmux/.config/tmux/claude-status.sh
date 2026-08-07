# shellcheck shell=bash
# Session-level Claude state for the fzf pickers.
#
# The hard part -- working out which Claude session owns which window -- is
# already done once a second by the tmux-powerline segment. collect.sh resolves
# each session's pid up its process tree to the pane that owns it and windows.sh
# stamps the result on that window as @cc_state. Reading those options back is
# one tmux call and no subprocesses, which is what makes this safe to run every
# time a popup opens; re-deriving the state here would mean jq over
# ~/.claude/sessions plus a walk of the whole process table.
#
# Two consequences of borrowing rather than deriving. State is only as fresh as
# the last segment tick, and a window that has never hosted a Claude session
# carries no option at all -- the segment strips it on exit. Both are fine for a
# list that is on screen for a second or two, and both fail closed: the row just
# renders as an ordinary session.
#
# Sourced, not executed. The caller needs CC_RANK in its own shell.

# Mirrors the palette in tmux-powerline/segments/claude_sessions.sh, where the
# rule is set out in full: only the waiting state is chromatic, everything else
# is a luminance ramp. Colour in the picker therefore means "this one needs you"
# and nothing else. The segment's values cannot be shared from here -- a tmux
# popup shell inherits none of tmux-powerline's environment -- so they are
# restated. Keep the two in step.
CC_C_WAIT="${CC_C_WAIT-$'\033[1;38;2;230;180;80m'}" # #e6b450, bold
CC_C_BUSY="${CC_C_BUSY-$'\033[38;2;172;182;191m'}"  # #acb6bf
CC_C_LIVE="${CC_C_LIVE-$'\033[38;2;191;189;182m'}"  # #bfbdb6
CC_C_DIM="${CC_C_DIM-$'\033[38;2;86;91;102m'}"      # #565b66
CC_C_NEW="${CC_C_NEW-$'\033[38;2;89;194;255m'}"     # #59c2ff
CC_C_OFF=$'\033[0m'

# Same glyphs the status bar uses, so a session reads identically in the picker
# and on the bar. Idle has no glyph: it is the resting state of nearly every
# session, and marking it would put a mark on almost every row.
CC_G_WAIT="${CC_G_WAIT-󰫢}"
CC_G_BUSY="${CC_G_BUSY-󰧞}"

# Width of the glyph column, in cells. The glyphs are Nerd Font private-use
# codepoints and single-width under Monaspace NF, so glyph-plus-space matches a
# two-space blank and the names stay aligned. If your terminal font renders them
# double-width the names will sit one cell out; widen CC_BLANK to three spaces.
CC_BLANK="${CC_BLANK-  }"

declare -gA CC_RANK=()

# Read every window's Claude state and reduce it to one rank per session.
cc_load() {
	CC_RANK=()
	local state name rank

	# State first, name second. A session name is free-form -- it comes from
	# `basename | tr './:' '-'`, which leaves '|' alone -- so it has to be the
	# field that absorbs the remainder of the line. Reversed, a name containing
	# the separator would be truncated and its state silently dropped.
	while IFS='|' read -r state name; do
		[ -n "$name" ] || continue
		case "$state" in
		waiting) rank=3 ;;
		busy) rank=2 ;;
		idle) rank=1 ;;
		*) rank=0 ;;
		esac

		# A session spans several windows and only one of them runs Claude, so
		# the session takes the most demanding state any of its windows is in.
		if [ "$rank" -gt "${CC_RANK[$name]:-0}" ]; then
			CC_RANK["$name"]=$rank
		fi
	done < <(tmux list-windows -a -F '#{@cc_state}|#{session_name}' 2>/dev/null)

	return 0
}

# Emit one fzf line as `display<TAB>value`.
#
# fzf renders and matches field 1 and returns field 2 (--with-nth/--accept-nth),
# so the glyph column and the escape sequences never reach the selection and the
# caller gets back exactly the string it passed in. Kinds:
#
#   session  a running tmux session, annotated with its Claude state
#   dir      a directory with no session yet -- dimmed, because the brightness
#            split between live and latent is what gives the list its hierarchy
#   new      the [new] sentinel
#   plain    no styling, blank column only. For pickers whose rows are all the
#            same kind, where dimming every row would say nothing; the blank
#            still buys the alignment that lets a [new] row sit among them.
cc_row() {
	local value="$1" kind="$2"
	local glyph="$CC_BLANK" color=""

	case "$kind" in
	session)
		color="$CC_C_LIVE"
		case "${CC_RANK[$value]:-0}" in
		3)
			glyph="${CC_G_WAIT} "
			color="$CC_C_WAIT"
			;;
		2)
			glyph="${CC_G_BUSY} "
			color="$CC_C_BUSY"
			;;
		esac
		;;
	new)
		glyph="+ "
		color="$CC_C_NEW"
		;;
	plain) ;;
	*)
		color="$CC_C_DIM"
		;;
	esac

	printf '%s%s%s%s\t%s\n' "$glyph" "$color" "$value" "$CC_C_OFF" "$value"
}
