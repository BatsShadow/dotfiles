#!/usr/bin/env bash
# Tests for focus-guard.sh, against a fake `aerospace` that plays back a list
# of focused windows, one per query, and logs every focus it is asked for.
# Crest's theft itself is a fact about Crest, measured by hand and written up
# in the library's header. These only cover what the guard does about it.
#
#   ./focus-guard.test.sh

set -u

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
LIB="$(cd .. && pwd)/focus-guard.sh"

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

# Fake aerospace. `list-windows --all` prints $WINDOWS_FILE as
# id|bundle|monitor. `list-windows --focused` takes the next line of
# $FOCUSED_FILE and keeps answering with the last one. `focus --window-id`
# appends to $FOCUS_LOG. `list-monitors --count` prints $MONITORS.
mkdir -p "$WORK/bin"
cat >"$WORK/bin/aerospace" <<'EOF'
#!/bin/bash
case "$1 $2" in
  "list-monitors --count") echo "$MONITORS" ;;
  "list-windows --all") cat "$WINDOWS_FILE" ;;
  "list-windows --focused")
    head -n 1 "$FOCUSED_FILE"
    [ "$(wc -l <"$FOCUSED_FILE")" -gt 1 ] && sed -i '' 1d "$FOCUSED_FILE"
    ;;
  "focus --window-id") echo "$3" >>"$FOCUS_LOG" ;;
esac
EOF
chmod +x "$WORK/bin/aerospace"
export PATH="$WORK/bin:$PATH"
export WINDOWS_FILE="$WORK/windows"
export FOCUSED_FILE="$WORK/focused"
export FOCUS_LOG="$WORK/focus-log"
export FOCUS_GUARD_TOKEN="$WORK/token"
export FOCUS_GUARD_TRIES=4

CREST=com.pauldavis.crest
WEZ=com.github.wez.wezterm

# shellcheck source=../focus-guard.sh
. "$LIB"

# 10 and 12 are Crest on monitor 2, 11 is Crest on monitor 1, 20 and 21 are
# WezTerm on monitor 2.
printf '%s\n' "10|$CREST|2" "11|$CREST|1" "12|$CREST|2" "20|$WEZ|2" "21|$WEZ|2" >"$WINDOWS_FILE"
export MONITORS=2
focused() { printf '%s\n' "$@" >"$FOCUSED_FILE"; }
focuses() { [ -f "$FOCUS_LOG" ] && paste -sd' ' - <"$FOCUS_LOG"; rm -f "$FOCUS_LOG"; }

echo "focus_guard"

focused "10|$CREST|2"
focus_guard_claim
focus_guard 10
assert_eq "10" "$(focuses)" "no theft: one focus, nothing undone"

focused "10|$CREST|2" "11|$CREST|1"
focus_guard_claim
focus_guard 10
assert_eq "10 10" "$(focuses)" "Crest raises its window on the other monitor: put back once"

focused "11|$CREST|1"
focus_guard_claim
focus_guard 10
assert_eq "10 10" "$(focuses)" "theft that lands before the first check is undone too"

focused "10|$CREST|2" "12|$CREST|2"
focus_guard_claim
focus_guard 10
assert_eq "10" "$(focuses)" "focus moved to a Crest window on the same monitor: left alone"

focused "10|$CREST|2" "20|$WEZ|2"
focus_guard_claim
focus_guard 10
assert_eq "10" "$(focuses)" "focus moved to another app: left alone"

focused "11|$CREST|1"
focus_guard_claim
echo 999999 >"$FOCUS_GUARD_TOKEN"
focus_guard 10
assert_eq "10" "$(focuses)" "a newer dispatch holds the token: its window is not pulled back"

focused "20|$WEZ|2" "21|$WEZ|2"
focus_guard_claim
focus_guard 20
assert_eq "" "$(focuses)" "not a Crest window: no focus and no wait"

MONITORS=1 focused "11|$CREST|1"
focus_guard_claim
MONITORS=1 focus_guard 10
assert_eq "10" "$(focuses)" "one monitor: focuses but never waits to undo"

focused "10|$CREST|2"
focus_guard_claim
focus_guard ""
assert_eq "" "$(focuses)" "no window to hold: does nothing"

focus_guard 99
assert_eq "" "$(focuses)" "a window that no longer exists: does nothing"

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
