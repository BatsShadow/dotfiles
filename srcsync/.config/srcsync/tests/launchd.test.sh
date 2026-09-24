#!/usr/bin/env bash
# The LaunchAgent install is idempotent: launchd tears down a bootstrapped
# agent's timer state on every bootstrap, so re-running install.sh must only
# call launchctl when the rendered plist actually changed. LAUNCH_AGENTS_DIR
# and LAUNCHCTL let the test point install.sh at a temp dir and a fake
# launchctl instead of the real ones.
#
#   ./launchd.test.sh

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LAUNCHD_DIR=$(cd "$TESTS/../launchd" && pwd -P)
LAUNCH_AGENTS_DIR="$WORK/LaunchAgents"
mkdir -p "$LAUNCH_AGENTS_DIR"
LOG="$WORK/launchctl.log"
:>"$LOG"

cat >"$WORK/launchctl" <<EOF
#!/bin/bash
echo "\$@" >>"$LOG"
EOF
chmod +x "$WORK/launchctl"

UID_NOW=$(id -u)
PLIST="$LAUNCH_AGENTS_DIR/com.batsshadow.srcsync.plist"

install_once() { # dir
	LAUNCH_AGENTS_DIR="$LAUNCH_AGENTS_DIR" LAUNCHCTL="$WORK/launchctl" "$1/install.sh"
}

printf 'first run renders and bootstraps\n'

# umask 000, as the main machine's shell has, made the plist world-writable,
# and launchd refuses those with "bad ownership/permissions" (error 5).
(umask 000 && install_once "$LAUNCHD_DIR")
rc=$?
assert_eq 0 "$rc" "install.sh exits 0"
assert_eq yes "$([ -e "$PLIST" ] && echo yes || echo no)" "plist exists"
assert_eq 0 "$(plutil -lint "$PLIST" >/dev/null 2>&1; echo $?)" "plutil -lint passes"
assert_eq 0 "$(grep -c '@HOME@' "$PLIST")" "no @HOME@ left in the rendered plist"
assert_eq 180 "$(plutil -extract StartInterval raw -o - "$PLIST")" "StartInterval is 180"
assert_eq /bin/bash "$(plutil -extract ProgramArguments.0 raw -o - "$PLIST")" "runs under /bin/bash"
assert_eq timer "$(plutil -extract ProgramArguments.3 raw -o - "$PLIST")" "last argument is timer"
assert_eq -rw-r--r-- "$(stat -f %Sp "$PLIST")" "the plist is 644 whatever the umask"

assert_eq "bootout gui/$UID_NOW/com.batsshadow.srcsync
bootstrap gui/$UID_NOW $PLIST" "$(cat "$LOG")" "fake launchctl saw bootout then bootstrap"

printf 'an unchanged plist makes no new launchctl calls\n'

before=$(wc -l <"$LOG" | tr -d ' ')
install_once "$LAUNCHD_DIR"
after=$(wc -l <"$LOG" | tr -d ' ')
assert_eq "$before" "$after" "second run calls launchctl no further times"

chmod 666 "$PLIST"
install_once "$LAUNCHD_DIR"
assert_eq $((after + 2)) "$(wc -l <"$LOG" | tr -d ' ')" \
	"a plist left world-writable is fixed and bootstrapped again"
assert_eq -rw-r--r-- "$(stat -f %Sp "$PLIST")" "and is 644 after"

printf 'a changed template bootstraps again\n'

PKG2="$WORK/launchd-changed"
mkdir -p "$PKG2"
cp "$LAUNCHD_DIR/com.batsshadow.srcsync.plist.in" "$LAUNCHD_DIR/install.sh" "$PKG2/"
chmod +x "$PKG2/install.sh"
awk '/<dict>/{print; print "\t<!-- test edit -->"; next} {print}' \
	"$PKG2/com.batsshadow.srcsync.plist.in" >"$PKG2/com.batsshadow.srcsync.plist.in.new"
mv "$PKG2/com.batsshadow.srcsync.plist.in.new" "$PKG2/com.batsshadow.srcsync.plist.in"

before=$(wc -l <"$LOG" | tr -d ' ')
install_once "$PKG2"
after=$(wc -l <"$LOG" | tr -d ' ')
assert_eq $((before + 2)) "$after" "changing the template makes install.sh bootstrap again"

printf 'a failed bootstrap is retried\n'

# The plist used to go into place before the bootstrap, so after a failed
# one the next install found it unchanged and never tried again.
FAIL_DIR="$WORK/LaunchAgents-fail"
mkdir -p "$FAIL_DIR"
FLOG="$WORK/launchctl-fail.log"
cat >"$WORK/launchctl-fail" <<EOF
#!/bin/bash
echo "\$@" >>"$FLOG"
[ "\$1" = bootstrap ] && [ ! -e "$WORK/bootstrap-ok" ] && exit 5
exit 0
EOF
chmod +x "$WORK/launchctl-fail"
LAUNCH_AGENTS_DIR="$FAIL_DIR" LAUNCHCTL="$WORK/launchctl-fail" "$LAUNCHD_DIR/install.sh" 2>/dev/null
assert_eq yes "$([ $? -ne 0 ] && echo yes || echo no)" "a failed bootstrap fails the install"
touch "$WORK/bootstrap-ok"
: >"$FLOG"
LAUNCH_AGENTS_DIR="$FAIL_DIR" LAUNCHCTL="$WORK/launchctl-fail" "$LAUNCHD_DIR/install.sh"
assert_eq 1 "$(grep -c '^bootstrap' "$FLOG")" "and the next install bootstraps again"

done_testing
