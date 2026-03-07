#!/usr/bin/env bash
# Remove a tmux session. If it's a worktree, also remove the git worktree.

export PATH="/opt/homebrew/bin:$PATH"

REPO_DIR="$HOME/src/upngo/upngo-web"
WORKTREE_DIR="$HOME/src/upngo/worktrees"

# Pick a session to remove (exclude the current session)
current=$(tmux display-message -p '#S')
selected=$(tmux list-sessions -F '#S' | grep -v "^${current}$" | fzf --prompt="remove session> ")

[[ -z "$selected" ]] && exit 0

# Check if it matches a worktree
worktree_path="$WORKTREE_DIR/$selected"
if [[ -d "$worktree_path" ]]; then
    git -C "$REPO_DIR" worktree remove "$worktree_path" || {
        echo "Failed to remove worktree. Force remove? (y/n)"
        read -rn1 confirm
        if [[ "$confirm" == "y" ]]; then
            git -C "$REPO_DIR" worktree remove --force "$worktree_path"
        else
            exit 1
        fi
    }
fi

tmux kill-session -t "$selected"
