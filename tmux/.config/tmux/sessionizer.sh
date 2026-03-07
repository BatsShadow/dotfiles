#!/usr/bin/env bash
# tmux-sessionizer: fuzzy-find a dir and open/switch to a tmux session for it

# Ensure homebrew binaries (fzf, etc.) are in PATH for tmux popup shells
export PATH="/opt/homebrew/bin:$PATH"

if [[ -n "$1" ]]; then
    selected="$1"
else
    selected=$(
        {
            find ~/src -mindepth 1 -maxdepth 1 -type d 2>/dev/null
            find ~/src/upngo/worktrees -mindepth 1 -maxdepth 1 -type d 2>/dev/null
            echo "$HOME/dotfiles"
        } | fzf --prompt="session> "
    )
fi

[[ -z "$selected" ]] && exit 0

# Remember last session directory for startup restoration
echo "$selected" > ~/.config/tmux/last-session

session_name=$(basename "$selected" | tr './:' '-')

if tmux has-session -t="$session_name" 2>/dev/null; then
    if [[ -n "$TMUX" ]]; then
        tmux switch-client -t "$session_name"
    else
        tmux attach-session -t "$session_name"
    fi
else
    tmux new-session -d -s "$session_name" -c "$selected" -n "vi"
    tmux send-keys -t "$session_name:vi" "vi" Enter

    tmux new-window -t "$session_name" -n "cli" -c "$selected"

    tmux new-window -t "$session_name" -n "claude" -c "$selected"
    tmux send-keys -t "$session_name:claude" "claude" Enter

    tmux select-window -t "$session_name:cli"

    if [[ -n "$TMUX" ]]; then
        tmux switch-client -t "$session_name"
    else
        tmux attach-session -t "$session_name"
    fi
fi
