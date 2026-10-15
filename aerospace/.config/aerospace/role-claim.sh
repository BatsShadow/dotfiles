#!/usr/bin/env bash
# Move the focused window to a workspace and, if its app has roles, make it
# that workspace's role window. Workspace mode's alt-shift-o/l/y.
# Usage: role-claim.sh Browser|Email|YouTube
#
# Moving an Arc window to Email is already a statement that it is the Email
# window, so the move key is the fix when adoption or a relaunch picked wrong.
# The focused id is read before the move, because a separate exec-and-forget
# would race the binding's own move and could claim whatever got focus after.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/window-roles.sh"
ROLE=${1:?"Usage: role-claim.sh <role>"}

INFO=$(aerospace list-windows --focused --format '%{window-id}|%{app-bundle-id}' 2>/dev/null)
ID=${INFO%%|*}
BUNDLE=${INFO#*|}
[ -n "$ID" ] && [ -n "$(role_opener "$BUNDLE")" ] && role_set "$ROLE" "$ID" "$BUNDLE"

aerospace move-node-to-workspace "$ROLE"
aerospace workspace "$ROLE"
"$SCRIPT_DIR/workspace-mode/auto-config.aerospace.sh"
