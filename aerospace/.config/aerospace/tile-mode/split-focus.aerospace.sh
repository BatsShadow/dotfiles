#!/usr/bin/env bash
set -x

CWD=$(pwd)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FOCUSED=$(aerospace list-windows --focused --json | jq '.[0]."window-id"')

if [ "$#" -gt 0 ]; then
  WINDOW=$($SCRIPT_DIR/../find-window.sh "$@")
  COUNT=$(echo $WINDOW | wc -w)
  if ((COUNT == 0)); then
    # TODO: launch app
    exit 0
  elif ((COUNT > 1)); then
    # This is only needed if the same app is focused, otherwise, just take the first oen
    if echo $WINDOW | grep -q $FOCUSED; then
      WINDOW=$(echo "$WINDOW"\\n"$WINDOW" | sed -n "/$FOCUSED/"'{n;p;q;}')
    else
      WINDOW=$(echo "$WINDOW" | head -n 1)
    fi
  fi
  echo WINDOW=$WINDOW
  aerospace swap --window-id $WINDOW left
  aerospace focus --window-id $WINDOW
  exit 0
fi

WORKSPACE=Tiles
WINDOWS=$(aerospace list-windows --all --json | jq '.[]."window-id"' | grep -v "$FOCUSED")

# Move to a blank screen to look more magic
# aerospace workspace BLANK

# Move all windows away from their current space just in case any of the windows were already here
for win in $WINDOWS; do
  aerospace move-node-to-workspace --window-id "$win" TEMP
done

# Start with the focused window
aerospace move-node-to-workspace --window-id $FOCUSED $WORKSPACE
aerospace workspace $WORKSPACE
aerospace focus --window-id $FOCUSED
aerospace layout v_accordion

for win in $WINDOWS; do
  aerospace move-node-to-workspace --window-id "$win" $WORKSPACE
done

aerospace focus --window-id $FOCUSED
aerospace move left
aerospace resize smart 1408
