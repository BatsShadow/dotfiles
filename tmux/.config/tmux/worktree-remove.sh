#!/usr/bin/env bash
# Remove a git worktree and kill its tmux session if one exists

export PATH="/opt/homebrew/bin:$PATH"

REPO_DIR="$HOME/src/upngo/upngo-web"
WORKTREE_DIR="$HOME/src/upngo/worktrees"

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
RESET='\033[0m'

current_session=""
if [[ -n "$TMUX" ]]; then
    current_session=$(tmux display-message -p '#S')
fi

# List worktree directories, excluding any that match the current session
selected=$(
    find "$WORKTREE_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | while IFS= read -r dir; do
        name=$(basename "$dir")
        [[ "$name" != "$current_session" ]] && echo "$dir"
    done | fzf --prompt="remove worktree> "
)

[[ -z "$selected" ]] && exit 0

branch=$(basename "$selected")

echo -e "${CYAN}Removing worktree ${YELLOW}$branch${RESET}"
git -C "$REPO_DIR" worktree remove "$selected" || {
    echo -e "${YELLOW}Failed to remove cleanly. Force remove? (y/n)${RESET}"
    read -rn1 confirm
    echo
    if [[ "$confirm" == "y" ]]; then
        git -C "$REPO_DIR" worktree remove --force "$selected" || {
            echo -e "${RED}Force remove failed${RESET}"
            sleep 2
            exit 1
        }
    else
        exit 1
    fi
}
echo -e "${GREEN}Worktree removed:${RESET} $selected"

# Kill the matching tmux session if it exists
if tmux has-session -t="$branch" 2>/dev/null; then
    tmux kill-session -t "$branch"
    echo -e "${GREEN}Session killed:${RESET} $branch"
fi

echo
read -rp "Press enter to continue..."
