#!/bin/sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CURRENT=`$SCRIPT_DIR/tmux-pane-list.sh | grep -iE '^1' |  cut -d ' ' -f 2`
echo $CURRENT
