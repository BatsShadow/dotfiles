#!/usr/bin/env bash
# Manage upngo worktrees: switch to existing or create new from upstream/main

export PATH="/opt/homebrew/bin:$PATH"

REPO_DIR="$HOME/src/upngo/upngo-web"
WORKTREE_DIR="$HOME/src/upngo/worktrees"
HISTORY_FILE="$HOME/.config/tmux/.session-history"
touch "$HISTORY_FILE"

current_session=""
if [[ -n "$TMUX" ]]; then
    current_session=$(tmux display-message -p '#S')
fi

# List existing worktrees sorted by recency, then [new] option
selected=$(
    {
        # Worktrees with active sessions, sorted by recency (excluding current)
        tail -r "$HISTORY_FILE" | awk '!seen[$0]++' | while IFS= read -r hist_name; do
            [[ "$hist_name" == "$current_session" ]] && continue
            dir="$WORKTREE_DIR/$hist_name"
            [[ -d "$dir" ]] && tmux has-session -t="$hist_name" 2>/dev/null && echo "$dir"
        done
        # Then remaining worktree dirs
        find "$WORKTREE_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null
        echo "[new]"
    } | awk '!seen[$0]++' | fzf --prompt="worktree> "
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
    if git -C "$REPO_DIR" show-ref --verify --quiet "refs/heads/$branch"; then
        git -C "$REPO_DIR" worktree add "$worktree_path" "$branch"
    else
        git -C "$REPO_DIR" worktree add -b "$branch" "$worktree_path" upstream/main
    fi || {
        echo "Failed to create worktree"
        sleep 2
        exit 1
    }

    selected="$worktree_path"
fi

exec ~/.config/tmux/sessionizer.sh "$selected"
