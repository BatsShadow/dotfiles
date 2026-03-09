#!/usr/bin/env bash

CWD=$(pwd)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOML_FILE="$SCRIPT_DIR/.workspace-window-modes.toml"

CURRENT_MONITOR=$(aerospace list-monitors --focused --format %{monitor-id})
XDR_ID=$(aerospace list-monitors | grep XDR | awk '{print $1}')

if [[ "$CURRENT_MONITOR" -ne "$XDR_ID" ]]; then
  echo Current monitor is not XDR. Exiting
  # Allow the script to run on laptop monitor when 0 is pressed
  if [[ "$1" == "" ]]; then
    exit 0
  fi
fi

CURRENT_WORKSPACE=$(aerospace list-workspaces --visible --monitor $XDR_ID)
SAVED_MODE=$(cat "$TOML_FILE" | grep "^$CURRENT_WORKSPACE = " | sed -e"s/^$CURRENT_WORKSPACE = //")
MONITOR_COUNT=$(aerospace list-monitors --count)

cd "$SCRIPT_DIR" || false

# write config file, then reload it

# write to a temp file, then move it to avoid issues
# with aerospace reading a partial file
TEMP_CONFIG=$(mktemp -t aerospace-config)
cat globals.toml >"${TEMP_CONFIG}"
cat split.gaps.toml >>"${TEMP_CONFIG}"
cat modes.toml >>"${TEMP_CONFIG}"
cp $TEMP_CONFIG ../aerospace.toml

aerospace reload-config
$SCRIPT_DIR/split-focus.aerospace.sh

# Persist current mode
echo "tile" > "$SCRIPT_DIR/../.current-mode"

cd "$CWD" || false
