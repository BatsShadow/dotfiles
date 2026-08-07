#!/usr/bin/env zsh

for d in *(/); stow -v -t ~/ -S $d
~/.config/tmux/plugins/tpm/bin/install_plugins
tmux source ~/.config/tmux/tmux.conf

# Claude Code's settings.json is written by Claude Code itself, so it is merged
# into rather than stowed -- see the script for why a symlink there is unsafe.
~/.claude/hooks/install-hooks.sh

# Generate initial aerospace.toml (tile mode as default)
~/.config/aerospace/tile-mode/auto-config.aerospace.sh 2>/dev/null || true
