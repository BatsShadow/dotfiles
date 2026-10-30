#!/usr/bin/env bash
# Tests for workspace-mode/column-count.sh, against a fake `osascript` that
# prints window frames from a file. The grouping is the decision under test;
# the frames themselves come from the window server, which a stub can't vouch
# for. The first case is the Terminal workspace as read on 2026-10-30.
#
#   ./column-count.test.sh

set -u

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
SCRIPT="$(cd .. && pwd)/workspace-mode/column-count.sh"

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

# Fake osascript: prints $FRAMES_FILE as id x y width height.
mkdir -p "$WORK/bin"
cat >"$WORK/bin/osascript" <<'EOF'
#!/bin/bash
cat "$FRAMES_FILE"
EOF
chmod +x "$WORK/bin/osascript"
export PATH="$WORK/bin:$PATH"
export FRAMES_FILE="$WORK/frames"

frames() { printf '%s\n' "$@" >"$FRAMES_FILE"; }
count() { "$SCRIPT" "$@"; }

echo "column-count"

frames "9578 1617 70 1071 1561" "8568 180 100 1417 1531" "164 180 70 1417 1531"
assert_eq 2 "$(count 9578 8568 164)" "Terminal: a tile beside a stacked pair is 2"

frames "1 10 40 1000 1500" "2 1020 40 1000 1500" "3 2030 40 1000 1500"
assert_eq 3 "$(count 1 2 3)" "three tiles side by side are 3"

frames "1 750 40 1000 1500" "2 1750 40 1000 1500"
assert_eq 2 "$(count 1 2)" "tiles with no gap between them are still 2"

frames "1 750 40 1600 1500" "2 780 40 1600 1500" "3 810 40 1600 1500"
assert_eq 1 "$(count 1 2 3)" "a sideways accordion offsets each window 30px: 1"

frames "1 10 40 1000 1500" "2 10 70 1000 1470" "3 1020 40 1000 1500" "4 1020 70 1000 1470"
assert_eq 2 "$(count 1 2 3 4)" "two separate stacked groups are 2, not 1"

frames "1 10 40 1000 750" "2 10 800 1000 740"
assert_eq 1 "$(count 1 2)" "a vertical split stays one column"

frames "1 0 40 900 1500" "2 800 40 800 1500"
assert_eq 2 "$(count 1 2)" "an app wider than its tile does not swallow its neighbour"

frames "3 2030 40 1000 1500" "1 10 40 1000 1500" "2 1020 40 1000 1500"
assert_eq 3 "$(count 1 2 3)" "frames in any order"

frames ""
assert_eq 0 "$(count)" "no windows: 0"

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
