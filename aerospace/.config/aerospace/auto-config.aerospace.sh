#!/usr/bin/env bash

CWD=$(pwd)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

XDR_ID=$(aerospace list-monitors | grep XDR | awk '{print $1}')
MONITOR_COUNT=$(aerospace list-monitors --count)

WINDOW_COUNT=3
if [ "$MONITOR_COUNT" -eq 2 ]; then
  WINDOW_COUNT=$(aerospace list-windows --monitor $XDR_ID --workspace visible --count)
fi

if [ "$WINDOW_COUNT" -eq 0 ]; then
  WINDOW_COUNT=1
fi

WINDOW_CHOICE_DESIRED=${1:-$WINDOW_COUNT}
GAP_ADJUSTMENT=$((30 / 2 * (WINDOW_COUNT - 1)))

GAPS="n-windows.gaps.toml"

if [ "$WINDOW_CHOICE_DESIRED" -eq 1 ]; then
  echo 1
  GAPS="one-window.gaps.toml"
elif [ "$WINDOW_CHOICE_DESIRED" -eq 2 ]; then
  echo 2
  GAPS="two-windows.gaps.toml"
fi

# write config file, then reload it
cd "$SCRIPT_DIR" || false
cat globals.toml >aerospace.toml
# // offset gaps for tiled windows
cat "$GAPS" | perl -pe"s/850/$((850 - $GAP_ADJUSTMENT))/" >>aerospace.toml
cat modes.toml >>aerospace.toml
aerospace reload-config
cd "$CWD" || false
