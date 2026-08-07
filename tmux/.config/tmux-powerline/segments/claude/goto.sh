#!/usr/bin/env bash
# Click target for a Claude session notification: put the waiting window in
# front of the user.
#
# Invoked by terminal-notifier -execute, which runs it detached from tmux, so
# the client has to be looked up rather than inherited from the environment.

target="$1"
app="${2:-WezTerm}"

[ -n "$target" ] || exit 0

client=$(tmux list-clients -F '#{client_name}' 2>/dev/null | head -1)
if [ -n "$client" ]; then
	# Switching the session and selecting the window are separate steps:
	# switch-client alone lands on whichever window that session last had.
	tmux switch-client -c "$client" -t "${target%%:*}" 2>/dev/null
	tmux select-window -t "$target" 2>/dev/null
fi

open -a "$app" 2>/dev/null
exit 0
