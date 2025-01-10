#!/usr/bin/env bash

CWD=$(pwd)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOML_FILE="$SCRIPT_DIR/.workspace-window-modes.toml"

CURRENT_MONITOR=$(aerospace list-monitors --focused --format %{monitor-id})
XDR_ID=$(aerospace list-monitors | grep XDR | awk '{print $1}')

if [[ "$CURRENT_MONITOR" -ne "$XDR_ID" ]]; then
  echo Current monitor is not XDR. Exiting
  exit 0
fi

CURRENT_WORKSPACE=$(aerospace list-workspaces --focused)
SAVED_MODE=$(cat "$TOML_FILE" | grep "^$CURRENT_WORKSPACE = " | sed -e"s/^$CURRENT_WORKSPACE = //")
MONITOR_COUNT=$(aerospace list-monitors --count)

WINDOW_COUNT=3
if [ "$MONITOR_COUNT" -eq 2 ]; then
  WINDOW_COUNT=$(aerospace list-windows --monitor $XDR_ID --workspace visible --count)
fi

if [ "$WINDOW_COUNT" -eq 0 ]; then
  WINDOW_COUNT=1
fi
echo WINDOW_COUNT: $WINDOW_COUNT
WINDOW_CHOICE_DESIRED=${1:-$WINDOW_COUNT}

if [ "$WINDOW_CHOICE_DESIRED" == "W" ]; then
  # Use saved mode if it exists
  if [ "$SAVED_MODE" != "" ]; then
    echo Restoring mode $SAVED_MODE
    WINDOW_CHOICE_DESIRED=$SAVED_MODE
  else
    echo Defaulting to $WINDOW_COUNT windows
    WINDOW_CHOICE_DESIRED=$WINDOW_COUNT
  fi
fi

GAP_ADJUSTMENT=$((30 / 2 * (WINDOW_COUNT - 1)))

GAPS="n-windows.gaps.toml"
LAYOUT=tiles

if [ "$WINDOW_CHOICE_DESIRED" -eq 1 ]; then
  echo Desired mode 1
  GAPS="one-window.gaps.toml"
  LAYOUT=accordion
elif [ "$WINDOW_CHOICE_DESIRED" -eq 2 ]; then
  echo Desired mode 2
  GAPS="two-windows.gaps.toml"
else
  echo Desired mode 3
fi

cd "$SCRIPT_DIR" || false
# write config file, then reload it
cat globals.toml >aerospace.toml
# // offset gaps for tiled windows
cat "$GAPS" | perl -pe"s/850/$((850 - $GAP_ADJUSTMENT))/" >>aerospace.toml
cat modes.toml >>aerospace.toml
aerospace layout $LAYOUT horizontal
aerospace reload-config

# save mode for later
. "$SCRIPT_DIR/save-window-mode.sh"

cd "$CWD" || false
