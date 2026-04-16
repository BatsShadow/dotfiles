#!/usr/bin/env bash
# Save the current pane's directory as the session's home directory

SESSION_DIRS_FILE="$HOME/.config/tmux/.session-dirs"
touch "$SESSION_DIRS_FILE"

session_name=$(tmux display-message -p '#S')
pane_dir=$(tmux display-message -p '#{pane_current_path}')

TAB=$(printf '\t')

# Remove old entry, append new one
grep -v "^${session_name}${TAB}" "$SESSION_DIRS_FILE" > "$SESSION_DIRS_FILE.tmp" 2>/dev/null || true
printf '%s\t%s\n' "$session_name" "$pane_dir" >> "$SESSION_DIRS_FILE.tmp"
mv "$SESSION_DIRS_FILE.tmp" "$SESSION_DIRS_FILE"

tmux display-message "Session dir saved: ${pane_dir}"
