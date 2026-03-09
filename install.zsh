#!/usr/bin/env zsh

for d in *(/); stow -v -t ~/ -S $d
~/.config/tmux/plugins/tpm/bin/install_plugins
tmux source ~/.config/tmux/tmux.conf

# Generate initial aerospace.toml (tile mode as default)
~/.config/aerospace/tile-mode/auto-config.aerospace.sh 2>/dev/null || true
