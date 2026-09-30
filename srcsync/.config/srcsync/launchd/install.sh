#!/bin/bash
# Installs the srcsync LaunchAgent, which runs `auto timer` every three
# minutes. A LaunchAgent rather than a daemon like kanata's, because it needs
# the user's ssh keys and runs as them, not as root. /bin/bash rather than a
# login shell, because that is what launchd invokes with and what srcsync.sh
# itself expects (its tests run it the same way). launchctl bootout tears
# down an agent's StartInterval timer, so a re-bootstrap only happens when the
# rendered plist actually changed; otherwise this is a silent no-op, safe to
# call on every install-srcsync.zsh run. A failed bootstrap removes the plist, so the
# next run retries it rather than finding it unchanged.
#
#   ./install.sh

set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
TEMPLATE="$SCRIPT_DIR/com.batsshadow.srcsync.plist.in"
LABEL=com.batsshadow.srcsync
LAUNCH_AGENTS_DIR="${LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
LAUNCHCTL="${LAUNCHCTL:-launchctl}"
PLIST="$LAUNCH_AGENTS_DIR/$LABEL.plist"

mkdir -p "$LAUNCH_AGENTS_DIR"

tmp="$PLIST.tmp.$$"
trap 'rm -f "$tmp"' EXIT
sed "s|@HOME@|$HOME|g" "$TEMPLATE" >"$tmp"
# launchd refuses a plist others can write, and umask 000 makes one
chmod 644 "$tmp"
plutil -lint "$tmp" >/dev/null

if [ -e "$PLIST" ] && cmp -s "$tmp" "$PLIST" && [ "$(stat -f %Lp "$PLIST")" = 644 ]; then
	exit 0
fi

mv -f "$tmp" "$PLIST"
trap - EXIT

"$LAUNCHCTL" bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
"$LAUNCHCTL" bootstrap "gui/$(id -u)" "$PLIST" || {
	rc=$?
	rm -f "$PLIST"
	exit $rc
}
