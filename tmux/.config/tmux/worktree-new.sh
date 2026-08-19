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

# Landed work is marked here, the same as in the picker that cleans it up. The
# call to load the marks was already below; without this the fallback stayed
# unset, so cc_row never consulted them and no row was ever marked. Set before
# the source, which is where claude-status.sh reads it.
export CC_FALLBACK=merged

# Row styling, shared with the session picker so [new] reads the same in both.
# Degrades to an unstyled list rather than failing to open; see sessionizer.sh.
CC_HELPER="${BASH_SOURCE[0]%/*}/claude-status.sh"
if [[ -r "$CC_HELPER" ]]; then
    # shellcheck source=claude-status.sh
    source "$CC_HELPER"
else
    cc_row() { printf '%s\t%s\n' "$1" "$1"; }
    cc_merged_load() { :; }
fi

# Marks branches that have already landed, so a finished worktree is visibly
# finished in the list you pick from as well as the one you clean up in.
cc_merged_load

current_session=""
if [[ -n "$TMUX" ]]; then
    current_session=$(tmux display-message -p '#S')
fi

# Which sessions exist, asked once. This was a `tmux has-session` per history
# entry, up to one per line the file keeps; at ~5ms a round trip that was the
# bulk of the wait before the list appeared, and none of it told us anything
# that a single list-sessions does not.
declare -A live=() emitted=()
while IFS= read -r name; do
    [[ -n "$name" ]] && live["$name"]=1
done < <(tmux list-sessions -F '#S' 2>/dev/null)

# List existing worktrees sorted by recency, then [new] option
selected=$(
    {
        # Worktrees with active sessions, sorted by recency (excluding current).
        #
        # `emitted` dedups on the value, which an awk pass in front of fzf used
        # to do -- the styled columns differ even when the paths behind them are
        # identical. In the shell it also keeps rows flowing to fzf as they are
        # produced; awk mid-pipe block-buffers, holding the whole list back
        # until the last row was built.
        while IFS= read -r hist_name; do
            [[ -n "$hist_name" && "$hist_name" != "$current_session" ]] || continue
            [[ -n "${live[$hist_name]:-}" ]] || continue
            dir="$WORKTREE_DIR/$hist_name"
            [[ -d "$dir" && -z "${emitted[$dir]:-}" ]] || continue
            emitted["$dir"]=1
            cc_row "$dir" plain
        done < <(tail -r "$HISTORY_FILE")

        # Then remaining worktree dirs
        while IFS= read -r dir; do
            [[ -n "$dir" && -z "${emitted[$dir]:-}" ]] || continue
            emitted["$dir"]=1
            cc_row "$dir" plain
        done < <(find "$WORKTREE_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)

        [[ -z "${emitted["[new]"]:-}" ]] && cc_row "[new]" new
    } | fzf --ansi \
        --delimiter='\t' --with-nth=1 --accept-nth=2 \
        --prompt="$PROMPT_PREFIX worktree> "
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
