#!/bin/sh
tmux list-panes -F '#{pane_active} #{pane_current_command}'
