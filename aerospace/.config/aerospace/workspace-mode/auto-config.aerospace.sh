#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/gaps.sh"

CURRENT_MONITOR=$(aerospace list-monitors --focused --format %{monitor-id})
XDR_ID=$(aerospace list-monitors --format '%{monitor-id} %{monitor-name}' | grep -i XDR | awk '{print $1}' | head -n1)
MONITOR_COUNT=$(aerospace list-monitors --count)

# Monitor workspace mode manages: the XDR when it's connected, otherwise the
# only/focused monitor. Without this fallback, a single-monitor setup leaves
# XDR_ID empty, which breaks every `--monitor $XDR_ID` query below.
TARGET_MONITOR="${XDR_ID:-$CURRENT_MONITOR}"

# With multiple monitors, workspace mode only manages the XDR, so a switch
# or move that lands focus on another monitor has nothing to re-gap. That
# includes W from dispatch.sh: it used to get through, reload the config for
# nothing, and save the XDR's mode under the other monitor's workspace. An
# explicit mode (alt-1/2/3) still applies from any monitor, and reload.sh sets
# AUTO_CONFIG_FORCE so a config edit reloads wherever focus is.
if [ "$MONITOR_COUNT" -ge 2 ] && [ -n "$XDR_ID" ] && [ "$CURRENT_MONITOR" != "$XDR_ID" ] &&
  [ -z "${AUTO_CONFIG_FORCE:-}" ] && { [ "$1" = "" ] || [ "$1" = "W" ]; }; then
  echo Current monitor is not XDR. Exiting
  exit 0
fi

CURRENT_WORKSPACE=$(aerospace list-workspaces --visible --monitor "$TARGET_MONITOR")
SAVED_MODE=$(gaps_saved_mode "$CURRENT_WORKSPACE")

# Tiled windows only: a floating one sits over the tiles, not in a column.
TILED=$(aerospace list-windows --monitor "$TARGET_MONITOR" --workspace visible \
  --format '%{window-id}|%{window-parent-container-layout}' | awk -F'|' '$2 != "floating" { print $1 }')
WINDOW_COUNT=$(echo "$TILED" | grep -c .)
if [ "$WINDOW_COUNT" -eq 0 ]; then
  WINDOW_COUNT=1
fi

WINDOW_CHOICE_DESIRED=$1
if [ "$WINDOW_CHOICE_DESIRED" == "W" ] && [ "$SAVED_MODE" != "" ]; then
  echo Restoring mode $SAVED_MODE
  WINDOW_CHOICE_DESIRED=$SAVED_MODE
fi

# The mode follows columns on screen, so a stacked group counts once. Counted
# only when no mode is given or saved: reading frames costs ~100ms, and
# almost every workspace has a saved mode. The gap adjustment below still
# takes WINDOW_COUNT: it makes room for accordion padding, which grows with
# every window.
if [ "$WINDOW_CHOICE_DESIRED" = "" ] || [ "$WINDOW_CHOICE_DESIRED" = "W" ]; then
  # shellcheck disable=SC2086
  COLUMN_COUNT=$("$SCRIPT_DIR/column-count.sh" $TILED)
  [ "${COLUMN_COUNT:-0}" -gt 0 ] || COLUMN_COUNT=1
  echo Defaulting to $COLUMN_COUNT columns
  WINDOW_CHOICE_DESIRED=$COLUMN_COUNT
fi

echo Desired mode $WINDOW_CHOICE_DESIRED

# Most switches land on the mode already loaded. A reload re-lays out every
# window on both screens, so skip it when nothing would change.
if gaps_install "$WINDOW_CHOICE_DESIRED" "$WINDOW_COUNT" || [ -n "${AUTO_CONFIG_FORCE:-}" ]; then
  aerospace reload-config
fi

# save mode for later
. "$SCRIPT_DIR/save-window-mode.sh"

# Persist current mode
echo "workspace" > "$SCRIPT_DIR/../.current-mode"
