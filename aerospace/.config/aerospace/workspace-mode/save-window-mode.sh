#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOML_FILE="$SCRIPT_DIR/.workspace-window-modes.toml"

WORKSPACE=$(aerospace list-workspaces --focused)
CURRENT_MODE=$(cat "${SCRIPT_DIR}/../aerospace.toml" | grep WINDOW-MODE | sed -e's/^.*WINDOW-MODE-//')

if grep -q "^${WORKSPACE} = " "$TOML_FILE"; then
  echo "Editing $WORKSPACE = $CURRENT_MODE"
  perl -i -pe"s/$WORKSPACE = .*/$WORKSPACE = $CURRENT_MODE/" "$TOML_FILE"
else
  echo "Adding $WORKSPACE = $CURRENT_MODE"
  echo "$WORKSPACE = $CURRENT_MODE" >>"$TOML_FILE"
fi
