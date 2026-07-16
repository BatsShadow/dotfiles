#!/usr/bin/env bash

CWD=$(pwd)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOML_FILE="$SCRIPT_DIR/.workspace-window-modes.toml"

CURRENT_MONITOR=$(aerospace list-monitors --focused --format %{monitor-id})
XDR_ID=$(aerospace list-monitors --format '%{monitor-id} %{monitor-name}' | grep -i XDR | awk '{print $1}' | head -n1)
MONITOR_COUNT=$(aerospace list-monitors --count)

# Monitor workspace mode manages: the XDR when it's connected, otherwise the
# only/focused monitor. Without this fallback, a single-monitor setup leaves
# XDR_ID empty, which breaks every `--monitor $XDR_ID` query below.
TARGET_MONITOR="${XDR_ID:-$CURRENT_MONITOR}"

# With multiple monitors, workspace mode only manages the XDR — so ignore
# auto/no-arg invocations fired while focused on a different monitor. On a
# single monitor there is nothing to bail out of, so this guard is skipped.
if [ "$MONITOR_COUNT" -ge 2 ] && [ -n "$XDR_ID" ] && [ "$CURRENT_MONITOR" != "$XDR_ID" ]; then
  # Allow the script to run on laptop monitor when 0 is pressed
  if [[ "$1" == "" ]]; then
    echo Current monitor is not XDR. Exiting
    exit 0
  fi
fi

CURRENT_WORKSPACE=$(aerospace list-workspaces --visible --monitor "$TARGET_MONITOR")
SAVED_MODE=$(cat "$TOML_FILE" | grep "^$CURRENT_WORKSPACE = " | sed -e"s/^$CURRENT_WORKSPACE = //")

# Exclude floating windows from the count
WINDOW_COUNT=$(aerospace list-windows --monitor "$TARGET_MONITOR" --workspace visible \
  --format '%{window-parent-container-layout}' | grep -cv '^floating$')

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

# write to a temp file, then move it to avoid issues
# with aerospace reading a partial file
TEMP_CONFIG=$(mktemp -t aerospace-config)
cat globals.toml >"${TEMP_CONFIG}"
# // offset gaps for tiled windows
cat "$GAPS" | perl -pe"s/850/$((850 - $GAP_ADJUSTMENT))/" >>"${TEMP_CONFIG}"
cat modes.toml >>"${TEMP_CONFIG}"
cp $TEMP_CONFIG ../aerospace.toml

aerospace reload-config

# save mode for later
. "$SCRIPT_DIR/save-window-mode.sh"

# Persist current mode
echo "workspace" > "$SCRIPT_DIR/../.current-mode"

cd "$CWD" || false
