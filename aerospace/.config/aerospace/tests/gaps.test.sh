#!/usr/bin/env bash
# Tests for workspace-mode/gaps.sh: what it renders, when it writes, and what
# gaps_prepare tells dispatch.sh to do. Runs against a copy of workspace-mode
# and a fake `aerospace`. Whether a batched reload-config and switch draw once
# is a fact about AeroSpace, seen by eye and written up in the header.
#
#   ./gaps.test.sh

set -u

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
SRC="$(cd .. && pwd)/workspace-mode"

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

# Fake aerospace. $WORKSPACES is workspace|monitor-name lines, $MONITORS the
# monitor count, $WS_LAYOUTS the layouts of the asked-for workspace's windows.
mkdir -p "$WORK/bin"
cat >"$WORK/bin/aerospace" <<'EOF'
#!/bin/bash
case "$*" in
  "list-workspaces --all"*) printf '%s\n' "${WORKSPACES[@]}" | tr ',' '\n' ;;
  "list-monitors --count") echo "$MONITORS" ;;
  "list-windows --workspace"*) printf '%s\n' $WS_LAYOUTS ;;
esac
EOF
chmod +x "$WORK/bin/aerospace"
export PATH="$WORK/bin:$PATH"

mkdir -p "$WORK/cfg/workspace-mode"
cp "$SRC"/*.sh "$SRC"/*.toml "$WORK/cfg/workspace-mode/"
export GAPS_MODES="$WORK/cfg/workspace-mode/.workspace-window-modes.toml"
CONFIG="$WORK/cfg/aerospace.toml"

# shellcheck source=../workspace-mode/gaps.sh
. "$WORK/cfg/workspace-mode/gaps.sh"

right() { grep '^outer.right' "$CONFIG" | grep -o 'XDR = [0-9]*' | cut -d' ' -f3; }
mode() { grep -o 'WINDOW-MODE-[0-9]' "$CONFIG" | cut -d- -f3; }

export WORKSPACES="Terminal|Pro Display XDR,Slack|Pro Display XDR,YouTube|Built-in Retina Display,New|Pro Display XDR"
export MONITORS=2 WS_LAYOUTS="h_accordion h_accordion h_accordion floating"
printf '%s\n' "Terminal = 1" "Slack = 2" "YouTube = 1" >"$GAPS_MODES"

echo "gaps_render / gaps_install"

: >"$CONFIG"
gaps_install 1 1
assert_eq "0 1 850" "$? $(mode) $(right)" "mode 1, one window: written, right gap 850"

gaps_install 1 1
assert_eq "1" "$?" "the same again: nothing to write"

gaps_install 1 3
assert_eq "0 820" "$? $(right)" "three windows: 30px less right gap"

gaps_install 2 3
assert_eq "0 2 320" "$? $(mode) $(right)" "mode 2 ignores the window count"

gaps_install 3 1
assert_eq "0 3" "$? $(mode)" "mode 3"

echo "gaps_prepare"

: >"$CONFIG"
gaps_prepare Terminal
assert_eq "0 1 1 820" "$? $GAPS_RELOAD $(mode) $(right)" "saved mode on the XDR: installed, floats not counted, reload"

gaps_prepare Terminal
assert_eq "0 0" "$? $GAPS_RELOAD" "already loaded: ready, no reload"

gaps_prepare Slack
assert_eq "0 1 2" "$? $GAPS_RELOAD $(mode)" "another mode: reload"

gaps_prepare YouTube
assert_eq "2 2" "$? $(mode)" "on the built-in: nothing to re-gap, config untouched"

gaps_prepare New
assert_eq "1 2" "$? $(mode)" "no saved mode: auto-config after the switch"

WORKSPACES="Terminal|Built-in Retina Display,Slack|LG" gaps_prepare Terminal
assert_eq "1" "$?" "two monitors and no XDR: left to auto-config, as before"

WORKSPACES="Terminal|Built-in Retina Display" MONITORS=1 gaps_prepare Terminal
assert_eq "0 1" "$? $(mode)" "a single monitor is managed"

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
