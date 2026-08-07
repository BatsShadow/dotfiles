#!/usr/bin/env bash
# tmux-sessionizer: fuzzy-find a dir and open/switch to a tmux session for it

# Ensure homebrew binaries (fzf, etc.) are in PATH for tmux popup shells
export PATH="/opt/homebrew/bin:$PATH"

HISTORY_FILE="$HOME/.config/tmux/.session-history"
SESSION_DIRS_FILE="$HOME/.config/tmux/.session-dirs"
touch "$HISTORY_FILE" "$SESSION_DIRS_FILE"

# Claude state annotation. A partial stow can leave this behind, and a picker
# that refuses to open is far worse than one that opens without colour, so the
# fallback degrades to the plain list this script produced before.
CC_HELPER="${BASH_SOURCE[0]%/*}/claude-status.sh"
if [[ -r "$CC_HELPER" ]]; then
    # shellcheck source=claude-status.sh
    source "$CC_HELPER"
else
    cc_load() { :; }
    cc_row() { printf '%s\t%s\n' "$1" "$1"; }
fi

TAB=$(printf '\t')

# Look up the saved directory for a session name
lookup_session_dir() {
    grep "^$1${TAB}" "$SESSION_DIRS_FILE" | tail -1 | cut -f2
}

# Save a session-name → directory mapping
save_session_dir() {
    # Remove old entry, append new one
    grep -v "^$1${TAB}" "$SESSION_DIRS_FILE" > "$SESSION_DIRS_FILE.tmp" 2>/dev/null || true
    printf '%s\t%s\n' "$1" "$2" >> "$SESSION_DIRS_FILE.tmp"
    mv "$SESSION_DIRS_FILE.tmp" "$SESSION_DIRS_FILE"
}

current_session=""
if [[ -n "$TMUX" ]]; then
    current_session=$(tmux display-message -p '#S')
fi

if [[ -n "$1" ]]; then
    selected="$1"
else
    # Build list: existing sessions, most recent first, excluding the current one.
    #
    # Every row is `display<TAB>value`. The display column carries the Claude
    # state glyph and the colour; the value is the bare session name or path the
    # rest of this script already expects, so nothing below the picker changes.
    cc_load
    selected=$(
        {
            # Existing tmux sessions sorted by recency, excluding current
            while IFS= read -r name; do
                [[ "$name" != "$current_session" ]] && cc_row "$name" session
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

            # No directories: this picker lists sessions only. A session is
            # created either from the current directory via [new], or by
            # worktree-new.sh, which does its own directory selection and then
            # hands the path to this script as $1.
            cc_row "[new]" new
            # Dedup on the value, not the whole row: two rows for the same
            # session would otherwise survive as soon as their glyphs differed.
        } | awk -F'\t' '!seen[$2]++' | fzf --ansi \
            --delimiter='\t' --with-nth=1 --accept-nth=2 \
            --ghost="session" \
            --prompt="session> "
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
    save_session_dir "$session_name" "$selected"
    echo "$session_name" >> "$HISTORY_FILE"
    tail -100 "$HISTORY_FILE" > "$HISTORY_FILE.tmp" && mv "$HISTORY_FILE.tmp" "$HISTORY_FILE"

    tmux new-session -d -s "$session_name" -c "$selected" -n "vi" "NVIM_APPNAME=lazyvim nvim; exec zsh -l"
    tmux new-window -t "$session_name" -n "cli" -c "$selected"
    tmux new-window -t "$session_name" -n "claude" -c "$selected" "claude -n '$session_name'; exec zsh -l"
    tmux select-window -t "$session_name:cli"
    tmux switch-client -t "$session_name"
    exit 0
fi

session_name=$(basename "$selected" | tr './:' '-')

# Resolve the working directory.
#
# A directory no longer reaches this point from the picker -- that lists only
# sessions -- but it is still the normal case for the two callers that pass $1:
# worktree-new.sh hands over the worktree it created, and .zshrc replays
# .last-session at shell startup. Removing this branch would break both.
#
# If selected is a directory path, use it directly and save the mapping.
# If selected is a session name, look up the saved dir.
if [[ -d "$selected" ]]; then
    session_dir="$selected"
    save_session_dir "$session_name" "$session_dir"
else
    session_dir=$(lookup_session_dir "$session_name")
    if [[ -z "$session_dir" || ! -d "$session_dir" ]]; then
        # Fallback: try to get the dir from the running session
        session_dir=$(tmux display-message -t "$session_name" -p '#{pane_current_path}' 2>/dev/null)
    fi
    if [[ -z "$session_dir" || ! -d "$session_dir" ]]; then
        session_dir="$HOME"
    fi
fi

# Remember last session directory for startup restoration
echo "$session_dir" > ~/.config/tmux/.last-session

# Record session switch in history
echo "$session_name" >> "$HISTORY_FILE"
# Keep history file from growing unbounded (last 100 entries)
tail -100 "$HISTORY_FILE" > "$HISTORY_FILE.tmp" && mv "$HISTORY_FILE.tmp" "$HISTORY_FILE"

# Check if session exists and has windows
needs_windows=false
if tmux has-session -t="$session_name" 2>/dev/null; then
    window_count=$(tmux list-windows -t "$session_name" 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$window_count" -eq 0 ]]; then
        tmux kill-session -t "$session_name" 2>/dev/null
        needs_windows=true
    fi
else
    needs_windows=true
fi

if [[ "$needs_windows" == "true" ]]; then
    tmux new-session -d -s "$session_name" -c "$session_dir" -n "vi" "NVIM_APPNAME=lazyvim nvim; exec zsh -l"
    tmux new-window -t "$session_name" -n "cli" -c "$session_dir"
    tmux new-window -t "$session_name" -n "claude" -c "$session_dir" "claude -n '$session_name'; exec zsh -l"
    tmux select-window -t "$session_name:cli"
fi

if [[ -n "$TMUX" ]]; then
    tmux switch-client -t "$session_name"
else
    exec tmux attach-session -t "$session_name"
fi
