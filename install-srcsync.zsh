#!/usr/bin/env zsh
# srcsync works in the background once it is installed: a LaunchAgent every
# three minutes, sleepwatcher on lid close and wake, Claude's Stop and
# SessionEnd hooks, and the sessionizer when it opens a worktree. install.zsh
# leaves all of it out, so none of it runs on a machine until this does.
#
# Every trigger but the LaunchAgent exits at once when
# ~/.config/srcsync/srcsync.sh is missing, so unstowing the package turns them
# off. The agent runs whether or not the script is there, so off unloads it.
# The code stays in the repo, and ~/.local/state/srcsync is kept either way.
#
#   ./install-srcsync.zsh       install and start
#   ./install-srcsync.zsh off   stop every trigger
cd "${0:A:h}"

case ${1:-on} in
on)
	brew list sleepwatcher &>/dev/null || brew install sleepwatcher
	stow -v -t ~/ -S srcsync
	~/.config/srcsync/launchd/install.sh
	# Runs the stowed ~/.sleep and ~/.wakeup, so srcsync publishes before the
	# lid closes and applies on wake.
	brew services start sleepwatcher
	~/.claude/hooks/install-hooks.sh
	;;
off)
	launchctl bootout gui/$(id -u)/com.batsshadow.srcsync 2>/dev/null
	rm -f ~/Library/LaunchAgents/com.batsshadow.srcsync.plist
	brew services stop sleepwatcher
	stow -v -t ~/ -D srcsync
	~/.claude/hooks/install-hooks.sh
	;;
*)
	echo "usage: $0 [off]" >&2
	exit 2
	;;
esac
