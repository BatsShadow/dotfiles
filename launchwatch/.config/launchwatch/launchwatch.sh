#!/bin/bash
# Warns before macOS runs out of app serial numbers, the fault that stops new
# apps opening until a reboot.
#
# Every process that checks in with launchservicesd gets an app serial number
# (ASN), apps and short-lived tools alike: each osascript run takes one. The
# serial is the launch count times 0x1001, a 64-bit value whose low 32 bits
# wrap after 1,048,320 launches. Past that, new apps stop registering. They
# open with no Cmd-Tab entry and ignore clicks, or never open at all. On
# 2026-10-31 Calculator failed to open at launch 1,108,218. On 2026-10-19 a
# Chrome that would not take clicks was launch 1,221,607. A tmux status segment
# running osascript twice a second got there in under a week, and the problem
# came back every week or two for years. A reboot resets the count, and
# nothing short of one is known to.
#
# The count comes from a serial this script takes itself: osascript checks in,
# asks lsappinfo for its own ASN and quits. lsappinfo prints only the low 32
# bits, but 4097 is odd, so multiplying by its inverse mod 2^32, 0xFFF001,
# gives the count back exactly. Checked against a serial logged with its high
# word, 0x1-0xea088fa: the full 64 bits divide by 4097 to 1,108,218, the same
# as the low word decodes to.
#
# The LaunchAgent runs this hourly. It notifies from WARN_AT on, at most once
# every EVERY seconds. terminal-notifier 2.0 has no action buttons, so a click
# on the notification is the button: it runs `restart`, which brings up
# macOS's own restart confirmation rather than restarting outright.
#
#   launchwatch.sh          check, and notify if due
#   launchwatch.sh count    print the launch count
#   launchwatch.sh restart  ask macOS to restart

set -u

WRAP=1048320
WARN_AT="${LAUNCHWATCH_WARN_AT:-900000}"
EVERY="${LAUNCHWATCH_EVERY:-21600}"
STATE="${LAUNCHWATCH_STATE:-$HOME/.local/state/launchwatch/last-notified}"
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

# launch_decode <low 32 bits of an ASN>: the launch count it was handed out at.
launch_decode() { echo $((($1 * 0xFFF001) & 0xFFFFFFFF)); }

launch_count() {
	local out low
	out=$(osascript -l JavaScript -e '
		ObjC.import("Foundation");
		const app = Application.currentApplication();
		app.includeStandardAdditions = true;
		app.doShellScript("lsappinfo find pid=" + $.NSProcessInfo.processInfo.processIdentifier);
	' 2>/dev/null)
	low=$(printf '%s\n' "$out" | sed -nE 's/.*ASN:0x[0-9a-fA-F]*-(0x[0-9a-fA-F]+).*/\1/p' | head -n 1)
	[ -n "$low" ] || return 1
	launch_decode "$low"
}

# Bash's printf ignores the locale for %'d.
commas() {
	local n="$1" out=""
	while [ ${#n} -gt 3 ]; do
		out=",${n:${#n}-3}$out"
		n=${n:0:${#n}-3}
	done
	echo "$n$out"
}

check() {
	local count now last title message
	count=$(launch_count) || {
		echo "$(date '+%F %T') could not read the launch count" >&2
		return 1
	}
	[ "$count" -ge "$WARN_AT" ] || return 0

	now="${LAUNCHWATCH_NOW:-$(date +%s)}"
	last=$(cat "$STATE" 2>/dev/null)
	[ $((now - ${last:-0})) -ge "$EVERY" ] || return 0

	if [ "$count" -ge "$WRAP" ]; then
		title="Restart now"
		message="$(commas "$count") app launches, past the $(commas "$WRAP") limit. New apps may not open. Click to restart."
	else
		title="Restart soon"
		message="$(commas "$count") of $(commas "$WRAP") app launches used. New apps stop opening at the limit. Click to restart."
	fi

	# -execute runs through a shell, so the path goes in single quotes, with
	# any quote inside it closed, escaped and reopened.
	terminal-notifier -title "$title" -message "$message" -group launchwatch \
		-execute "'${SELF//\'/\'\\\'\'}' restart" >/dev/null || return 1
	mkdir -p "$(dirname "$STATE")"
	echo "$now" >"$STATE"
	echo "$(date '+%F %T') notified at launch $count"
}

case "${1:-check}" in
check) check ;;
count) launch_count ;;
restart) osascript -e 'tell application "loginwindow" to «event aevtrrst»' ;;
*)
	echo "usage: $0 [check|count|restart]" >&2
	exit 2
	;;
esac
