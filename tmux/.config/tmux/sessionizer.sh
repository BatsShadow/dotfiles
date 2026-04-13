#!/usr/bin/env bash
# tmux-sessionizer: fuzzy-find a dir and open/switch to a tmux session for it

# Ensure homebrew binaries (fzf, etc.) are in PATH for tmux popup shells
export PATH="/opt/homebrew/bin:$PATH"

HISTORY_FILE="$HOME/.config/tmux/.session-history"
touch "$HISTORY_FILE"

current_session=""
if [[ -n "$TMUX" ]]; then
    current_session=$(tmux display-message -p '#S')
fi

if [[ -n "$1" ]]; then
    selected="$1"
else
    # Build list: recent sessions first (excluding current), then directories for new sessions
    selected=$(
        {
            # Existing tmux sessions sorted by recency, excluding current
            while IFS= read -r name; do
                [[ "$name" != "$current_session" ]] && echo "$name"
            done < <(
                # Read history in reverse (most recent last → most recent first after tac)
                tail -r "$HISTORY_FILE" | awk '!seen[$0]++' | while IFS= read -r hist_name; do
                    tmux has-session -t="$hist_name" 2>/dev/null && echo "$hist_name"
                done
                # Then any sessions not in history
                tmux list-sessions -F '#S' 2>/dev/null | while IFS= read -r s; do
                    [[ "$s" != "$current_session" ]] && ! grep -qxF "$s" "$HISTORY_FILE" && echo "$s"
                done
            )

            # Directories for creating new sessions
            find ~/src -mindepth 1 -maxdepth 1 -type d 2>/dev/null
            find ~/src/upngo/worktrees -mindepth 1 -maxdepth 1 -type d 2>/dev/null
            echo "$HOME/dotfiles"
            echo "[new]"
        } | awk '!seen[$0]++' | fzf --prompt="session> "
    )
fi

[[ -z "$selected" ]] && exit 0

if [[ "$selected" == "[new]" ]]; then
    current_dir=$(tmux display-message -p '#{pane_current_path}')
    session_name=$(basename "$current_dir" | tr './:' '-')

    if tmux has-session -t="$session_name" 2>/dev/null; then
        echo "Session '$session_name' already exists"
        sleep 1
        exit 1
    fi

    selected="$current_dir"

    echo "$selected" > ~/.config/tmux/.last-session
    echo "$session_name" >> "$HISTORY_FILE"
    tail -100 "$HISTORY_FILE" > "$HISTORY_FILE.tmp" && mv "$HISTORY_FILE.tmp" "$HISTORY_FILE"

    tmux new-session -d -s "$session_name" -c "$selected" -n "vi" "NVIM_APPNAME=lazyvim nvim; exec zsh -l"
    tmux new-window -t "$session_name" -n "cli" -c "$selected"
    tmux new-window -t "$session_name" -n "claude" -c "$selected" "claude; exec zsh -l"
    tmux select-window -t "$session_name:cli"
    tmux switch-client -t "$session_name"
    exit 0
fi

# Remember last session directory for startup restoration
echo "$selected" > ~/.config/tmux/.last-session

session_name=$(basename "$selected" | tr './:' '-')

# Record session switch in history
echo "$session_name" >> "$HISTORY_FILE"
# Keep history file from growing unbounded (last 100 entries)
tail -100 "$HISTORY_FILE" > "$HISTORY_FILE.tmp" && mv "$HISTORY_FILE.tmp" "$HISTORY_FILE"

if tmux has-session -t="$session_name" 2>/dev/null; then
    if [[ -n "$TMUX" ]]; then
        tmux switch-client -t "$session_name"
    else
        exec tmux attach-session -t "$session_name"
    fi
else
    tmux new-session -d -s "$session_name" -c "$selected" -n "vi" "NVIM_APPNAME=lazyvim nvim; exec zsh -l"
    tmux new-window -t "$session_name" -n "cli" -c "$selected"
    tmux new-window -t "$session_name" -n "claude" -c "$selected" "claude; exec zsh -l"

    tmux select-window -t "$session_name:cli"

    if [[ -n "$TMUX" ]]; then
        tmux switch-client -t "$session_name"
    else
        exec tmux attach-session -t "$session_name"
    fi
fi
