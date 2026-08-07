# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

macOS dotfiles managed with [GNU Stow](https://www.gnu.org/software/stow/). Each top-level directory is a stow package that mirrors the home directory structure (e.g., `zsh/.zshrc` symlinks to `~/.zshrc`, `kanata/.config/kanata/config.kbd` symlinks to `~/.config/kanata/config.kbd`).

## Installation

```bash
# Symlink all packages to home directory
./install.zsh

# Install a single package
stow -v -t ~/ -S <package-name>
```

The install script iterates all top-level directories, stows them, then installs tmux plugins and reloads the tmux config.

## Package Layout

- **zsh** — Shell config split across `.zshenv` (env vars, brew init, cargo), `.zprofile` (PATH, oh-my-zsh setup, oh-my-posh prompt), `.zshrc` (aliases, keybindings, zoxide, eza). Private env vars in `private.env` (not committed).
- **git** — `.gitconfig` with extensive aliases (see `[alias]` section). Uses `diff-so-fancy` for diffs. Conditional includes for different work contexts.
- **kanata** — Keyboard remapping via Kanata with Karabiner VirtualHIDDevice drivers. Installed from Homebrew, run as LaunchDaemons (`sudo kanata/.config/kanata/install.sh`). Colemak-DH with home row mods in `config.kbd`; `fn+R` live-reloads it.
- **tmux** — Prefix is `Ctrl+Space`. Plugins managed by TPM (plugins dir is gitignored). Catppuccin theme. vim-tmux-navigator for seamless vim/tmux pane switching.
- **lazyvim** — Neovim config based on LazyVim. Custom plugins in `lua/plugins/`. Uses Catppuccin theme.
- **wezterm** — Terminal emulator config in `wezterm.lua`.
- **aerospace** — Tiling window manager. Has two layout modes (tile-mode, workspace-mode) with helper scripts.
- **claude** — Claude Code hooks. `claude-waiting.sh` marks a session as waiting on you when it has asked a question and gone unanswered, which no file Claude Code writes records; the tmux status bar reads those markers. `settings.json` is deliberately not stowed — Claude Code writes it itself — so `install-hooks.sh` merges the registration in, and `install.zsh` runs it. Tests: `claude/.claude/hooks/tests/run.sh`.
- **brew** — `Brewfile` for Homebrew dependencies.
- **karabiner** — Karabiner-Elements complex modifications (used alongside Kanata for virtual HID).

## Key Conventions

- Shell uses **vi mode** (`bindkey -v`) with oh-my-zsh vi-mode plugin.
- Neovim is aliased as `vi` and uses `NVIM_APPNAME=lazyvim`.
- Editor is set to `/opt/homebrew/bin/nvim`.
- `eza` replaces `ls` when available; `zoxide` replaces `cd`.
- Tmux auto-starts in zsh sessions.
