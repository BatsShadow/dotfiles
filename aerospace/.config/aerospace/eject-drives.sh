#!/usr/bin/env bash
# Eject every attached external drive in one keypress, so the dock can be
# unplugged without a trip through Finder.
#
# Ejecting a *whole* disk takes all of its partitions with it -- that is what
# Finder's "Eject All" button does. The `physical` filter is load-bearing:
# without it diskutil also returns mounted disk images, and this machine keeps
# several iOS Simulator images mounted at all times.

set -uo pipefail

# Volume names reach this verbatim, so escape any quote that would otherwise
# terminate the AppleScript string and lose the notification entirely.
notify() {
  osascript -e "display notification \"${1//\"/\\\"}\" with title \"Eject\"" &
}

# Join lines into "a, b, c". paste -d takes a *list* of delimiters and cycles
# through it, so a literal ", " would alternate comma and space instead.
join_commas() {
  paste -sd ',' - | sed 's/,/, /g'
}

# Mount points belonging to a whole disk, one per line. APFS synthesizes a
# separate disk node for the container and the volumes mount under *that*, not
# under the physical disk, so both nodes have to be matched. The greedy capture
# before " (" is deliberate: volume names can themselves contain " (".
volumes_of() {
  local nodes node
  nodes="${1##*/} $(diskutil list "$1" | sed -n 's/.*Container \(disk[0-9]*\).*/\1/p' | tr '\n' ' ')"
  for node in $nodes; do
    mount | sed -nE "s|^/dev/${node}s[0-9]+ on (.*) \(.*|\1|p"
  done
}

# Process names holding a disk's volumes open. +f makes lsof read the argument
# as a whole file system rather than a single path.
holders_of() {
  volumes_of "$1" | while read -r mount_point; do
    lsof -Fc +f -- "$mount_point" 2>/dev/null | sed -n 's/^c//p'
  done | sort -u | join_commas
}

disks=$(diskutil list external physical | awk '/^\/dev\/disk[0-9]+ \(.*physical.*\)/ {print $1}')

if [ -z "$disks" ]; then
  notify "No external drives attached"
  exit 0
fi

# A running backup holds the destination open. Ask it to stop and give backupd
# a moment to let go, rather than forcing the unmount out from under a
# half-written backup.
if tmutil status 2>/dev/null | grep -q 'Running = 1'; then
  notify "Stopping Time Machine backup..."
  tmutil stopbackup
  for _ in $(seq 20); do
    tmutil status 2>/dev/null | grep -q 'Running = 1' || break
    sleep 0.5
  done
fi

ejected=""
failed=""

for disk in $disks; do
  # Collect names before ejecting -- afterwards there is nothing left to ask.
  names=$(volumes_of "$disk" | sed 's|.*/||' | join_commas)
  [ -n "$names" ] || names="${disk##*/}"

  # A straggling writer usually lets go within a second, so one retry saves
  # most of the failures that a single attempt would report.
  if ! diskutil eject "$disk" >/dev/null 2>&1; then
    sleep 1
    if ! diskutil eject "$disk" >/dev/null 2>&1; then
      holders=$(holders_of "$disk")
      [ -n "$holders" ] && names="$names (held by $holders)"
      failed="${failed:+$failed; }$names"
      continue
    fi
  fi

  ejected="${ejected:+$ejected, }$names"
done

message=""
[ -n "$ejected" ] && message="Safe to unplug: $ejected"
[ -n "$failed" ] && message="${message:+$message. }Still busy: $failed"

notify "$message"
[ -z "$failed" ]
