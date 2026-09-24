#!/usr/bin/env bash
# Test for the srcsync status bar segment. Standalone, no tmux server needed:
# run_segment only reads files named by SRCSYNC_STATE and SRCSYNC_CONFIG.
#
#   ./srcsync.test.sh

set -u

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

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
assert_eq() { # want got label
	if [ "$1" = "$2" ]; then
		pass "$3"
	else
		fail "$3" "expected: [$1]" "actual:   [$2]"
	fi
}
done_testing() {
	printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
	[ "$FAIL" -eq 0 ]
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export SRCSYNC_STATE="$WORK/state"
export SRCSYNC_CONFIG="$WORK/config"
mkdir -p "$SRCSYNC_STATE"

# shellcheck source=srcsync.sh
source ./srcsync.sh

write_conflicts() { # count
	local i out="["
	for ((i = 0; i < $1; i++)); do
		[ "$i" -gt 0 ] && out+=","
		out+="{\"repo\":\"r$i\",\"worktree\":\"w$i\",\"host\":\"h\",\"mine\":{},\"theirs\":{}}"
	done
	out+="]"
	printf '%s' "$out" >"$SRCSYNC_STATE/conflicts.json"
}

age_ts() { # minutes ago
	date -u -v-"$1"M +%Y-%m-%dT%H:%M:%SZ
}

printf 'auto off\n'
printf 'auto off\n' >"$SRCSYNC_CONFIG"
write_conflicts 2
assert_eq "" "$(run_segment)" "auto off prints nothing even with conflicts"
rm -f "$SRCSYNC_STATE/conflicts.json"

printf 'auto on\n'
printf 'auto on\n' >"$SRCSYNC_CONFIG"

write_conflicts 2
assert_eq "⇄ !2" "$(run_segment)" "2 conflicts print the count"
rm -f "$SRCSYNC_STATE/conflicts.json"

age_ts 20 >"$SRCSYNC_STATE/last-success"
assert_eq "⇄ 20m" "$(run_segment)" "20 minutes old prints minutes"

age_ts 180 >"$SRCSYNC_STATE/last-success"
assert_eq "⇄ 3h" "$(run_segment)" "3 hours old prints hours"

age_ts 5 >"$SRCSYNC_STATE/last-success"
assert_eq "" "$(run_segment)" "5 minutes old prints nothing"

rm -f "$SRCSYNC_STATE/last-success"
assert_eq "⇄ never" "$(run_segment)" "missing last-success prints never"

printf 'auto parsing matches load_config\n'

# A trailing comment on the auto line: load_config's `read -r kw a b` puts it
# in $b and ignores it, same as any other line.
printf 'auto on   # turn it on\n' >"$SRCSYNC_CONFIG"
write_conflicts 1
assert_eq "⇄ !1" "$(run_segment)" "a trailing comment on the auto line is ignored"
rm -f "$SRCSYNC_STATE/conflicts.json"

# Several auto lines: load_config keeps overwriting CFG_AUTO, so the last one
# wins, not "any line matched".
printf 'auto on\nauto off\n' >"$SRCSYNC_CONFIG"
write_conflicts 1
assert_eq "" "$(run_segment)" "auto off after auto on wins, like load_config's last write"
rm -f "$SRCSYNC_STATE/conflicts.json"

printf 'auto off\nauto on\n' >"$SRCSYNC_CONFIG"
write_conflicts 1
assert_eq "⇄ !1" "$(run_segment)" "auto on after auto off wins the same way"
rm -f "$SRCSYNC_STATE/conflicts.json"

done_testing
