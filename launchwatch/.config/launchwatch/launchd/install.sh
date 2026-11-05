#!/bin/bash
# Installs the launchwatch LaunchAgent, which runs launchwatch.sh hourly. The
# same steps as srcsync's installer, whose header explains them: launchctl
# bootout tears down a StartInterval timer, so this only re-bootstraps when
# the rendered plist changed, and is a silent no-op on every other run.
#
#   ./install.sh

set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
LABEL=com.batsshadow.launchwatch
TEMPLATE="$SCRIPT_DIR/$LABEL.plist.in"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

mkdir -p "$(dirname "$PLIST")"

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

launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$PLIST" || {
	rc=$?
	rm -f "$PLIST"
	exit $rc
}
