#!/bin/sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
$SCRIPT_DIR/tmux-current-pane-proc.sh | grep -iE 'zsh$' && exit 0
exit 1
