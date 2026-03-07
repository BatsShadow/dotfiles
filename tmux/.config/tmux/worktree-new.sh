#!/usr/bin/env bash
# Manage upngo worktrees: switch to existing or create new from upstream/main

export PATH="/opt/homebrew/bin:$PATH"

REPO_DIR="$HOME/src/upngo/upngo-web"
WORKTREE_DIR="$HOME/src/upngo/worktrees"

# List existing worktrees + [new] option
selected=$(
    {
        find "$WORKTREE_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null
        echo "[new]"
    } | fzf --prompt="worktree> "
)

[[ -z "$selected" ]] && exit 0

if [[ "$selected" == "[new]" ]]; then
    read -rp "new branch name> " branch
    [[ -z "$branch" ]] && exit 0

    worktree_path="$WORKTREE_DIR/$branch"

    if [[ -d "$worktree_path" ]]; then
        echo "Worktree '$branch' already exists"
        sleep 1
        exit 1
    fi

    git -C "$REPO_DIR" fetch upstream main
    git -C "$REPO_DIR" worktree add -b "$branch" "$worktree_path" upstream/main || {
        echo "Failed to create worktree"
        sleep 2
        exit 1
    }

    selected="$worktree_path"
fi

exec ~/.config/tmux/sessionizer.sh "$selected"
