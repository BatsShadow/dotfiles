#!/usr/bin/env zsh

# Stow folds a directory into a single symlink when it creates that directory
# itself. We want that one level down -- hooks/ and skills/ each as a single
# link -- but not for ~/.claude, which would put Claude Code's session state
# (600M+ of transcripts, history and caches) inside the checkout. Creating
# ~/.claude first stops the fold there and lets the two leaves fold.
mkdir -p ~/.claude

for d in *(/); stow -v -t ~/ -S $d
~/.config/tmux/plugins/tpm/bin/install_plugins
tmux source ~/.config/tmux/tmux.conf

# Claude Code's settings.json is written by Claude Code itself, so it is merged
# into rather than stowed -- see the script for why a symlink there is unsafe.
~/.claude/hooks/install-hooks.sh
# The hook only sees turns that end after it exists, and a session parked on a
# question produces no more turns. Catch up the ones already stuck.
~/.claude/hooks/claude-waiting-backfill.sh

# Generate initial aerospace.toml (tile mode as default)
~/.config/aerospace/tile-mode/auto-config.aerospace.sh 2>/dev/null || true
