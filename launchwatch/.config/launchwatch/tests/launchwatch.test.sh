#!/usr/bin/env bash
# Tests for launchwatch.sh: the decode, when it notifies and what it says.
# Runs against a fake osascript that hands out $ASN and logs a restart, and a
# fake terminal-notifier that logs its arguments. Whether macOS really fails
# past the wrap, and whether the click brings up the restart dialog, are
# facts about macOS, written up in the script's header.
#
#   ./launchwatch.test.sh

set -u

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
SCRIPT="$(cd .. && pwd)/launchwatch.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
pass() {
	PASS=$((PASS + 1))
	printf '  ok   %s\n' "$1"
}
fail() {
	FAIL=$((FAIL + 1))
	printf '  FAIL %s\n' "$1"
	shift
	local l
	for l in "$@"; do printf '         %s\n' "$l"; done
}
assert_eq() {
	if [ "$1" = "$2" ]; then pass "$3"; else
		fail "$3" "expected: [$1]" "got:      [$2]"
	fi
}

mkdir -p "$WORK/bin"
cat >"$WORK/bin/osascript" <<'EOF'
#!/bin/bash
case "$*" in
  *JavaScript*) [ -n "$ASN" ] && echo "ASN:0x0-$ASN-\"osascript\":" ;;
  *) echo "osascript $*" >>"$LOG" ;;
esac
EOF
cat >"$WORK/bin/terminal-notifier" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" >"$LOG.notify"
echo notify >>"$LOG"
EOF
chmod +x "$WORK/bin/osascript" "$WORK/bin/terminal-notifier"
export PATH="$WORK/bin:$PATH"
export LOG="$WORK/log"
export LAUNCHWATCH_STATE="$WORK/state/last-notified"

# The serial for a launch count, as macOS hands it out.
asn() { printf '0x%x' $((($1 * 0x1001) & 0xFFFFFFFF)); }
run() { "$SCRIPT" "$@" >/dev/null 2>&1; }
reset() { rm -rf "$LOG" "$LOG.notify" "$WORK/state"; }
log() { [ -f "$LOG" ] && paste -sd' ' - <"$LOG"; }
arg() { grep -A1 -x -- "$1" "$LOG.notify" | tail -n 1; }

echo "decode"

assert_eq "1073" "$(ASN=0x431431 "$SCRIPT" count)" "a serial from just after boot"
assert_eq "1108218" "$(ASN=0xea088fa "$SCRIPT" count)" "Calculator's failed launch, past the wrap"
assert_eq "1221607" "$(ASN=0x2a5113e7 "$SCRIPT" count)" "the Chrome that took no clicks"
assert_eq "4000000" "$(ASN=$(asn 4000000) "$SCRIPT" count)" "round trip well past the wrap"

ASN="" run count
assert_eq "1" "$?" "no serial: count fails"

echo "check"

reset
ASN=$(asn 899999) LAUNCHWATCH_NOW=100000 run
assert_eq "" "$(log)" "below the threshold: no notification"

reset
ASN=$(asn 900000) LAUNCHWATCH_NOW=100000 run
assert_eq "notify" "$(log)" "at the threshold: notified"
assert_eq "Restart soon" "$(arg -title)" "titled restart soon"
assert_eq "900,000 of 1,048,320 app launches used. New apps stop opening at the limit. Click to restart." \
	"$(arg -message)" "says how far along it is"
assert_eq "'$SCRIPT' restart" "$(arg -execute)" "a click runs restart"
assert_eq "100000" "$(cat "$LAUNCHWATCH_STATE")" "the time is recorded"

: >"$LOG"
ASN=$(asn 950000) LAUNCHWATCH_NOW=$((100000 + 21599)) run
assert_eq "" "$(log)" "under 6 hours later: quiet"

ASN=$(asn 950000) LAUNCHWATCH_NOW=$((100000 + 21600)) run
assert_eq "notify" "$(log)" "6 hours later: notified again"

reset
ASN=$(asn 1048320) LAUNCHWATCH_NOW=100000 run
assert_eq "Restart now" "$(arg -title)" "at the wrap: restart now"
assert_eq "1,048,320 app launches, past the 1,048,320 limit. New apps may not open. Click to restart." \
	"$(arg -message)" "and says it is past the limit"

reset
ASN="" LAUNCHWATCH_NOW=100000 run
assert_eq "1 " "$? $(log)" "no serial: fails without notifying"

reset
run restart
case "$(log)" in
*'«event aevtrrst»'*) pass "restart asks loginwindow, which shows the confirmation" ;;
*) fail "restart asks loginwindow" "got: [$(log)]" ;;
esac

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
