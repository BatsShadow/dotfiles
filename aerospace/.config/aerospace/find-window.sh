#!/usr/bin/env bash

VALUE=$1
shift
FILTER=${1:---workspace focused}
shift
FIELD=${1:-"window-title"}
shift

# Optional: exclude windows matching this pattern (passed as remaining args: --exclude <pattern>)
EXCLUDE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --exclude) EXCLUDE="$2"; shift 2 ;;
    *) shift ;;
  esac
done

if [ -n "$EXCLUDE" ]; then
  WINDOW=$(aerospace list-windows $FILTER --json |
    jq '.[] | select((."'"$FIELD"'" | contains("'"$VALUE"'")) and (."window-title" | test("'"$EXCLUDE"'"; "i") | not))."window-id"')
else
  WINDOW=$(aerospace list-windows $FILTER --json |
    jq '.[] | select(."'"$FIELD"'" | contains("'"$VALUE"'"))."window-id"')
fi

echo "$WINDOW"
