#!/usr/bin/env bash

VALUE=$1
shift
FILTER=${1:---workspace focused}
shift
FIELD=${1:-"window-title"}
shift
WINDOW=$(aerospace list-windows $FILTER --json |
  jq '.[] | select(."'"$FIELD"'" | contains("'"$VALUE"'"))."window-id"')

echo "$WINDOW"
