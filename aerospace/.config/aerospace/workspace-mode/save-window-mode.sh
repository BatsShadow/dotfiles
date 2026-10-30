#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOML_FILE="$SCRIPT_DIR/.workspace-window-modes.toml"

# The mode belongs to the workspace the XDR shows, which auto-config passes in
# as CURRENT_WORKSPACE. The focused one can be on the other monitor.
WORKSPACE=${CURRENT_WORKSPACE:-$(aerospace list-workspaces --focused)}
[ -n "$WORKSPACE" ] || return 0 2>/dev/null || exit 0
CURRENT_MODE=$(cat "${SCRIPT_DIR}/../aerospace.toml" | grep WINDOW-MODE | sed -e's/^.*WINDOW-MODE-//')

if grep -q "^${WORKSPACE} = " "$TOML_FILE"; then
  echo "Editing $WORKSPACE = $CURRENT_MODE"
  perl -i -pe"s/$WORKSPACE = .*/$WORKSPACE = $CURRENT_MODE/" "$TOML_FILE"
else
  echo "Adding $WORKSPACE = $CURRENT_MODE"
  echo "$WORKSPACE = $CURRENT_MODE" >>"$TOML_FILE"
fi
