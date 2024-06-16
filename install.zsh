#!/usr/bin/env zsh

for d in *(/); stow -v -t ~/ -S $d
~/.config/tmux/plugins/tpm/bin/install_plugins
tmux source ~/.config/tmux/tmux.conf
