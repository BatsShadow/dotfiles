#!/usr/bin/env bash
# Tests for workspace-mode/auto-config.aerospace.sh: when it reloads, when it
# reads frames, and which workspace its mode is saved under. It writes
# ../aerospace.toml next to itself, so each case runs a copy of
# workspace-mode in a scratch directory, against a fake `aerospace` that logs
# reload-config and a fake `osascript` that logs being asked for frames.
#
#   ./auto-config.test.sh

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

# Monitor 1 is the built-in, 2 the XDR. $FOCUSED_MON and $FOCUSED_WS say where
# focus is, $XDR_WS what the XDR shows, $WINDOWS its windows as id|layout.
mkdir -p "$WORK/bin"
cat >"$WORK/bin/aerospace" <<'EOF'
#!/bin/bash
case "$*" in
  "list-monitors --focused"*) echo "$FOCUSED_MON" ;;
  "list-monitors --format"*) printf '1 Built-in Retina Display\n2 Pro Display XDR\n' ;;
  "list-monitors --count") echo 2 ;;
  "list-workspaces --visible --monitor 2") echo "$XDR_WS" ;;
  "list-workspaces --focused") echo "$FOCUSED_WS" ;;
  "list-windows"*) printf '%s\n' $WINDOWS ;;
  "reload-config") echo reload >>"$LOG" ;;
esac
EOF
# Frames for two tiles side by side, whatever ids are asked for.
cat >"$WORK/bin/osascript" <<'EOF'
#!/bin/bash
echo frames >>"$LOG"
printf '1 10 40 1000 1500\n2 1020 40 1000 1500\n'
EOF
chmod +x "$WORK/bin/aerospace" "$WORK/bin/osascript"
export PATH="$WORK/bin:$PATH"
export LOG="$WORK/log"

# A fresh copy of workspace-mode with the given saved modes, and an
# aerospace.toml already holding mode $1.
setup() {
	local loaded="$1"
	shift
	rm -rf "$WORK/cfg" "$LOG"
	mkdir -p "$WORK/cfg/workspace-mode"
	cp "$SRC"/*.sh "$SRC"/*.toml "$WORK/cfg/workspace-mode/"
	printf '%s\n' "$@" >"$WORK/cfg/workspace-mode/.workspace-window-modes.toml"
	(
		cd "$WORK/cfg/workspace-mode" || exit 1
		XDR_WS=x FOCUSED_WS=x FOCUSED_MON=2 WINDOWS="1|h_tiles" LOG=/dev/null ./auto-config.aerospace.sh "$loaded" >/dev/null
	)
	rm -f "$LOG"
}
run() { (cd "$WORK/cfg/workspace-mode" && ./auto-config.aerospace.sh "$@" >/dev/null); }
log() { [ -f "$LOG" ] && paste -sd' ' - <"$LOG"; }
mode() { grep -o 'WINDOW-MODE-[0-9]' "$WORK/cfg/aerospace.toml" | cut -d- -f3; }
saved() { grep "^$1 = " "$WORK/cfg/workspace-mode/.workspace-window-modes.toml" | cut -d' ' -f3; }

export XDR_WS=Terminal FOCUSED_WS=Terminal FOCUSED_MON=2 WINDOWS="1|h_tiles 2|h_tiles"

echo "off the XDR"

setup 1 "Terminal = 1"
FOCUSED_MON=1 FOCUSED_WS=YouTube run W
assert_eq "" "$(log)" "W with focus on the built-in: no frames, no reload"
assert_eq "" "$(saved YouTube)" "and nothing saved under the built-in's workspace"

setup 1 "Terminal = 1"
FOCUSED_MON=1 FOCUSED_WS=YouTube run 2
assert_eq "reload" "$(log)" "an explicit mode from the built-in still applies"
assert_eq "2" "$(saved Terminal)" "saved under the workspace the XDR shows"
assert_eq "" "$(saved YouTube)" "not under the focused one"

setup 1 "Terminal = 1"
FOCUSED_MON=1 FOCUSED_WS=YouTube AUTO_CONFIG_FORCE=1 run W
assert_eq "reload" "$(log)" "reload.sh's force gets past the exit"

echo "on the XDR"

setup 1 "Terminal = 2"
run W
assert_eq "reload" "$(log)" "a saved mode is used without reading frames"
assert_eq "2" "$(mode)" "and is the mode loaded"

setup 1
run W
assert_eq "frames reload" "$(log)" "no saved mode: columns from frames"
assert_eq "2" "$(mode)" "two tiles side by side give mode 2"

setup 1
run
assert_eq "frames reload" "$(log)" "no argument: columns from frames"

setup 2 "Terminal = 2"
run W
assert_eq "" "$(log)" "the mode already loaded: no reload"

setup 2 "Terminal = 2"
AUTO_CONFIG_FORCE=1 run W
assert_eq "reload" "$(log)" "unless forced"

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
