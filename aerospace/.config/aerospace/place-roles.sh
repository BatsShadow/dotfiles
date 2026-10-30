#!/usr/bin/env bash
# Move each remembered browser window to its role's workspace. Workspace
# mode's after-startup-command.
#
# Window ids belong to macOS, so the ones in .window-roles still name the same
# windows after an AeroSpace restart, as long as the browser kept running.
# The title rules in on-window-detected are the only other routing there is,
# and a title follows the page: a Browser window playing a video reads as
# YouTube. A role is named after its workspace, so the id says where it goes.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/window-roles.sh"

# Read the whole file first: role_window rewrites it to drop a dead entry.
ROLES=$(cat "$ROLES_FILE" 2>/dev/null)
while IFS=$'\t' read -r role _ bundle; do
  [ -n "$role" ] || continue
  id=$(role_window "$role" "$bundle") || continue
  aerospace move-node-to-workspace --window-id "$id" "$role"
done <<<"$ROLES"
