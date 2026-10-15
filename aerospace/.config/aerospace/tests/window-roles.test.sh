#!/usr/bin/env bash
# Tests for window-roles.sh, against a fake `aerospace` that prints a window
# list from a file. The library only ever asks AeroSpace for that one list, so
# a stub holds every fact these decisions rest on. Nothing here is a claim
# about AeroSpace's own behaviour.
#
#   ./window-roles.test.sh

set -u

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
LIB="$(cd .. && pwd)/window-roles.sh"

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

# Fake aerospace: `list-windows --all --format ...` prints $WINDOWS_FILE, which
# the tests write as id<TAB>bundle<TAB>workspace, the format the library asks for.
mkdir -p "$WORK/bin"
cat >"$WORK/bin/aerospace" <<'EOF'
#!/bin/bash
[ "$1" = list-windows ] && cat "$WINDOWS_FILE"
EOF
chmod +x "$WORK/bin/aerospace"
export PATH="$WORK/bin:$PATH"
export WINDOWS_FILE="$WORK/windows"
export ROLES_FILE="$WORK/roles"
export ROLE_WAIT_TRIES=3

ARC=company.thebrowser.Browser
CREST=com.pauldavis.crest
T=$'\t'

# shellcheck source=../window-roles.sh
. "$LIB"

windows() { printf '%s\n' "$@" | tr '|' '\t' >"$WINDOWS_FILE"; }
roles() { if [ $# -eq 0 ]; then : >"$ROLES_FILE"; else printf '%s\n' "$@" | tr '|' '\t' >"$ROLES_FILE"; fi; }
roles_now() { tr '\t' '|' <"$ROLES_FILE" | sort | paste -sd' ' -; }

echo "role_find"

windows "10|$ARC|Email" "11|$ARC|Browser"
rm -f "$ROLES_FILE"
assert_eq 10 "$(role_find Email $ARC)" "no file: adopts the app's window on the role's workspace"
assert_eq "Email|10|$ARC" "$(roles_now)" "the adopted window is remembered"

windows "10|$ARC|Discord" "11|$ARC|Email"
roles "Email|10|$ARC"
assert_eq 10 "$(role_find Email $ARC)" "a remembered window wins even after it is moved off the workspace"

windows "11|$ARC|Email"
roles "Email|10|$ARC"
assert_eq 11 "$(role_find Email $ARC)" "remembered window gone: adopts what is on the workspace"
assert_eq "Email|11|$ARC" "$(roles_now)" "the dead id is replaced, not kept beside the new one"

windows "10|com.apple.Safari|Email"
roles "Email|10|$ARC"
assert_eq "" "$(role_find Email $ARC)" "an id now owned by another app is not this role's window"
assert_eq "" "$(roles_now)" "and the stale entry is dropped"

windows "11|$ARC|Email" "12|$ARC|Email"
roles "Browser|11|$ARC"
assert_eq 12 "$(role_find Email $ARC)" "adoption skips a window another role has claimed"

windows "11|$ARC|Email"
roles "Browser|11|$ARC"
assert_eq "" "$(role_find Email $ARC)" "only a claimed window on the workspace: nothing to adopt"

windows "20|$CREST|Tiles" "21|$ARC|Tiles"
roles
assert_eq "" "$(role_find Email $ARC)" "tile mode: everything is on Tiles, so nothing is adopted"

echo "role_set"

roles "Email|10|$ARC" "Browser|11|$ARC"
role_set Email 12 $ARC
assert_eq "Browser|11|$ARC Email|12|$ARC" "$(roles_now)" "a new window for a role replaces the old one"

roles "Email|10|$ARC" "Browser|11|$ARC"
role_set Email 11 $ARC
assert_eq "Email|11|$ARC" "$(roles_now)" "claiming another role's window takes it from that role"

roles "Email|10|$ARC"
role_set Email 20 $CREST
assert_eq "Email|10|$ARC Email|20|$CREST" "$(roles_now)" "roles are per app, so Arc and Crest keep separate Email windows"

echo "role_of"

roles "Email|10|$ARC" "YouTube|11|$ARC"
assert_eq YouTube "$(role_of 11 $ARC)" "finds a window's role"
assert_eq "" "$(role_of 11 $CREST)" "only for the app that owns the entry"
assert_eq "" "$(role_of 99 $ARC)" "nothing for an unknown window"

echo "role_create"

# A fake opener that adds window 30 to the list, as Arc showing a new window.
cat >"$WORK/opener" <<EOF
#!/bin/bash
echo "\$1" >"$WORK/opened-role"
printf '30${T}$ARC${T}Browser\n' >>"$WINDOWS_FILE"
EOF
chmod +x "$WORK/opener"
role_opener() { echo "$WORK/opener"; }

windows "10|$ARC|Email"
roles "Email|10|$ARC"
assert_eq 30 "$(role_create YouTube $ARC)" "returns the window that appeared, not one already open"
assert_eq YouTube "$(cat "$WORK/opened-role")" "the opener is told which role it is opening"
assert_eq "Email|10|$ARC YouTube|30|$ARC" "$(roles_now)" "the new window is remembered"

printf '#!/bin/bash\n' >"$WORK/opener"
windows "10|$ARC|Email"
roles
role_create YouTube $ARC >/dev/null
assert_eq 1 "$?" "fails when no window appears"
assert_eq "" "$(roles_now)" "and remembers nothing"

role_opener() { :; }
role_create YouTube $CREST >/dev/null
assert_eq 1 "$?" "an app with no opener has no roles"

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
