#!/usr/bin/env bash
# Manage upngo worktrees: switch to existing or create new from upstream/main
# Usage: worktree-new.sh [web|android]

export PATH="/opt/homebrew/bin:$PATH"

PROJECT="${1:-web}"

case "$PROJECT" in
    web)
        REPO_DIR="$HOME/src/upngo/upngo-web"
        PROMPT_PREFIX="web"
        ;;
    android)
        REPO_DIR="$HOME/src/upngo/upngo-android"
        PROMPT_PREFIX="android"
        ;;
    *)
        echo "Unknown project: $PROJECT (expected web or android)"
        exit 1
        ;;
esac

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
    } | awk '!seen[$0]++' | fzf --prompt="$PROMPT_PREFIX worktree> "
)

[[ -z "$selected" ]] && exit 0

if [[ "$selected" == "[new]" ]]; then
    read -rp "new branch name> " branch
    branch=$(printf '%s' "$branch" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9\n' '-' | tr -s '-' | sed 's/^-//;s/-$//')
    [[ -z "$branch" ]] && exit 0

    worktree_path="$WORKTREE_DIR/$branch"

    if [[ -d "$worktree_path" ]]; then
        echo "Worktree '$branch' already exists"
        sleep 1
        exit 1
    fi

    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    RED='\033[0;31m'
    CYAN='\033[0;36m'
    RESET='\033[0m'

    echo -e "${CYAN}Fetching upstream/main...${RESET}"
    git -C "$REPO_DIR" fetch upstream main

    if git -C "$REPO_DIR" show-ref --verify --quiet "refs/heads/$branch"; then
        echo -e "${CYAN}Checking out existing branch ${YELLOW}$branch${RESET}"
        git -C "$REPO_DIR" worktree add "$worktree_path" "$branch"
    else
        echo -e "${CYAN}Creating new branch ${YELLOW}$branch${CYAN} from upstream/main${RESET}"
        git -C "$REPO_DIR" worktree add -b "$branch" "$worktree_path" upstream/main
    fi || {
        echo -e "${RED}Failed to create worktree${RESET}"
        sleep 2
        exit 1
    }

    echo -e "${GREEN}Worktree created:${RESET} $worktree_path"

    # Hard link local_config.env from upngo-web into the new worktree
    if [[ "$PROJECT" == "web" ]]; then
        local_config="$REPO_DIR/local_config.env"
        if [[ -f "$local_config" ]]; then
            ln "$local_config" "$worktree_path/local_config.env"
            echo -e "${GREEN}Hard Linked:${RESET} local_config.env"
        else
            echo -e "${YELLOW}Warning:${RESET} $local_config not found, skipping"
        fi
    fi

    echo
    read -rp "Press enter to continue..."
    selected="$worktree_path"
fi

exec ~/.config/tmux/sessionizer.sh "$selected"
