#!/usr/bin/env bash
# Click target for a Claude session notification: put the waiting window in
# front of the user.
#
# Invoked by terminal-notifier -execute, which runs it detached from tmux, so
# the client has to be looked up rather than inherited from the environment.

target="$1"
app="${2:-WezTerm}"

[ -n "$target" ] || exit 0

# Nothing here can be reported to the person who clicked -- there is no
# terminal attached and no exit status anyone will see -- so the only way a
# failure leaves a trace is the system log. `log show --predicate
# 'process == "logger"'`, or Console.app, will find these.
note() { /usr/bin/logger -t cc-goto "$*" 2>/dev/null || true; }

# terminal-notifier runs -execute through /bin/sh -c with its own inherited
# environment, which frequently does not carry /opt/homebrew/bin. Resolving
# tmux from PATH alone meant it was simply not found: client came back empty,
# the switch was skipped, and the script fell through to `open -a`, which
# raises the terminal on whatever window happened to be current. With thirty-odd
# sessions live that reads as the feature not working at all -- and landing in
# the right window is the whole reason terminal-notifier was chosen over
# osascript.
#
# Where to look when PATH comes up empty. Overridable so the tests can exercise
# the fallback against a stub -- pointing it at a real tmux would mean running
# switch-client against the developer's own live server -- and so a tmux
# installed somewhere unusual can be named without editing this file.
CC_GOTO_TMUX_PATHS="${CC_GOTO_TMUX_PATHS:-/opt/homebrew/bin/tmux /usr/local/bin/tmux /usr/bin/tmux}"

tmux_bin="$(command -v tmux 2>/dev/null)"
if [ -z "$tmux_bin" ]; then
	# Deliberately unquoted: the value is a list of candidate paths.
	# shellcheck disable=SC2086
	for candidate in $CC_GOTO_TMUX_PATHS; do
		if [ -x "$candidate" ]; then
			tmux_bin="$candidate"
			break
		fi
	done
fi

if [ -z "$tmux_bin" ]; then
	note "no tmux binary found for ${target}; PATH=${PATH}"
	open -a "$app" 2>/dev/null
	exit 1
fi

client=$("$tmux_bin" list-clients -F '#{client_name}' 2>/dev/null | head -1)
if [ -n "$client" ]; then
	# Switching the session and selecting the window are separate steps:
	# switch-client alone lands on whichever window that session last had.
	"$tmux_bin" switch-client -c "$client" -t "${target%%:*}" 2>/dev/null
	"$tmux_bin" select-window -t "$target" 2>/dev/null
else
	# The terminal still comes up, but on whatever was last current -- so say
	# which window the click should have reached.
	note "no attached tmux client; cannot switch to ${target}"
fi

open -a "$app" 2>/dev/null
exit 0
