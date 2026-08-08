#!/usr/bin/env bash
# Kill tmux sessions. Tab to check several, Enter to remove them.
#
# Sessions only. This used to remove the matching git worktree too, which made
# the lowercase key -- the one that reads as "close this terminal" -- delete
# work from disk. Nothing is lost by separating them: X removes a worktree and
# kills its session as a consequence, so "clean this branch up entirely" is
# still one keystroke, just the capital one that already signals the heavier
# action. A session killed here is rebuilt by `prefix f` in a second.
#
# Rows carry the Claude state, idle sessions included. Everywhere else an
# unmarked row means "nothing worth mentioning"; here it has to mean "no Claude
# at all", because the question being asked is whether anything is still running
# inside before it gets killed.

export PATH="/opt/homebrew/bin:$PATH"

# Idle Claudes are marked here specifically. See above.
export CC_SHOW_IDLE=1

CC_HELPER="${BASH_SOURCE[0]%/*}/claude-status.sh"
if [[ -r "$CC_HELPER" ]]; then
	# shellcheck source=claude-status.sh
	source "$CC_HELPER"
else
	cc_load() { :; }
	cc_merged_load() { :; }
	cc_row() { printf '%s\t%s\n' "$1" "$1"; }
fi

cc_load
cc_merged_load

current=""
[[ -n "${TMUX:-}" ]] && current=$(tmux display-message -p '#S')

now=$(date +%s)

# How long since anything happened in a session. This is the whole of what
# "stale" means here -- deliberately shown rather than acted on, because a
# session quiet for a day may be the one you care most about resuming.
age_of() {
	local secs="$1" mins
	mins=$(((now - secs) / 60))
	if ((mins < 60)); then
		printf '%dm idle' "$mins"
	elif ((mins < 1440)); then
		printf '%dh idle' "$((mins / 60))"
	else
		printf '%dd idle' "$((mins / 1440))"
	fi
}

mapfile -t selected < <(
	tmux list-sessions -F '#{session_name}|#{session_activity}|#{session_attached}' 2>/dev/null |
		sort -t'|' -k2,2n |
		while IFS='|' read -r name activity attached; do
			[[ "$name" == "$current" ]] && continue

			note="$(age_of "$activity")"
			[[ "$attached" != "0" ]] && note="${note}, attached"

			cc_row "$name" session "$note"
			# Stalest first: the list is read top-down and the top is where the
			# safe answers are.
		done | fzf --ansi --multi \
		--delimiter='\t' --with-nth=1 --accept-nth=2 \
		--ghost="tab to check, enter to kill" \
		--prompt="kill session> " \
		--header="nothing on disk is touched"
)

((${#selected[@]})) || exit 0

printf '\n  killing %d session(s):\n\n' "${#selected[@]}"
printf '    %s\n' "${selected[@]}"
printf '\n'

# Explicit and defaulting to no. Checking rows in fzf is easy to do by accident
# -- Tab is next to the keys you navigate with -- so the checked list gets
# stated back before anything happens to it.
read -rp "  proceed? (y/N) " confirm
[[ "$confirm" == "y" || "$confirm" == "Y" ]] || exit 0

for name in "${selected[@]}"; do
	if tmux kill-session -t "$name" 2>/dev/null; then
		printf '    killed %s\n' "$name"
	else
		printf '    FAILED %s\n' "$name"
	fi
done

printf '\n'
read -rp "  press enter to continue..."
