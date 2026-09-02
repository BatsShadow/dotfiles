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
- **tmux** — Prefix is `Ctrl+Space`. Plugins managed by TPM (plugins dir is gitignored). Catppuccin theme. vim-tmux-navigator for seamless vim/tmux pane switching. `live-sessions.sh` records which sessions are open so a reboot does not take the list of in-progress work with it; `session-created`/`session-closed` hooks maintain it, and a server killed by signal fires neither, which is exactly why the file outlives the reboot. Outliving it was only half the job: the first session opened on the next server used to rewrite the file from the live set and erase the list seconds into the new boot, so names from before are held in `.live-sessions.carry`, keyed by the pid of the server that last wrote it, and written back alongside the live ones until reopened. `prefix f` then lists the recorded-but-not-running sessions dimmed alongside the live ones and rebuilds one on selection. `claude-continue.sh` opens the session's claude window on the conversation the directory already holds, or on a fresh one where it holds none: `claude -c` errors out instead of falling back, which left every new session staring at a bare shell. Tests: `tmux/.config/tmux/tests/`.
- **lazyvim** — Neovim config based on LazyVim. Custom plugins in `lua/plugins/`. Uses Catppuccin theme.
- **wezterm** — Terminal emulator config in `wezterm.lua`.
- **yazi** — Terminal file manager. `flavors/` is gitignored the same way tmux's plugins are; `ya pkg install` refills it from the revisions `package.toml` pins, and `install.zsh` runs that on a fresh machine. `ayu-mirage` is the exception and is committed: upstream still targets the Yazi 0.3 schema, so it is ported by hand and `ya pkg` would overwrite the port, which is why `.gitignore` exempts that one directory. Image previews need the Kitty graphics protocol to survive two hops, so they depend on `allow-passthrough` in tmux and `enable_kitty_graphics` in wezterm.
- **aerospace** — Tiling window manager. Has two layout modes (tile-mode, workspace-mode) with helper scripts.
- **claude** — Claude Code hooks and skills. `claude-waiting.sh` marks a session as waiting on you when it has asked a question and gone unanswered, which no file Claude Code writes records; the tmux status bar reads those markers. `claude-waiting-backfill.sh` catches up sessions already parked on a question before the hook saw them — they emit no further turns, so nothing else would ever mark them. `session-start-skills.sh` prints the skills that apply to every session — unslop today — for a SessionStart hook to inject, because a skill that has to be in force before the first word is written never gets loaded by a trigger. `settings.json` is deliberately not stowed — Claude Code writes it itself — so `install-hooks.sh` merges both registrations in; `install.zsh` runs them. Tests: `claude/.claude/hooks/tests/`. `skills/` holds global agent skills, one directory per skill; it is stowed as a single symlink, so a skill added under `~/.claude/skills` lands in this repo with no re-stow. Only `hooks/` and `skills/` are stowed: everything else under `~/.claude` is Claude Code's own state (600M+ of transcripts, history and caches) and must stay out of the repo. `install.zsh` pre-creates `~/.claude` for that reason — stow folds a directory it creates itself into a single symlink, so without it a fresh machine would swallow all of `~/.claude` into the checkout.
- **brew** — `Brewfile` for Homebrew dependencies.
- **karabiner** — Karabiner-Elements complex modifications (used alongside Kanata for virtual HID).

## Key Conventions

- Shell uses **vi mode** (`bindkey -v`) with oh-my-zsh vi-mode plugin.
- Neovim is aliased as `vi` and uses `NVIM_APPNAME=lazyvim`.
- Editor is set to `/opt/homebrew/bin/nvim`.
- `eza` replaces `ls` when available; `zoxide` replaces `cd`.
- Tmux auto-starts in zsh sessions.

## Git Workflow

**Don't create a branch unless asked.** Changes here are usually one small
config edit at a time, verified by reloading the thing you just edited. A
branch wraps that loop in a merge and a cleanup for a review that never comes.
Work directly in the checkout instead.

Suggest a branch only for genuinely larger work — a multi-step project that
will sit unfinished across sessions, or a change big enough to want a clean
escape hatch.

**Still ask before committing, and ask before pushing.** Branching is the only
step this section removes; it is not a grant of autonomy over git.
