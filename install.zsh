#!/usr/bin/env zsh
cd "${0:A:h}"

# A new Mac has no Homebrew, and stow, tmux and the rest come from it.
if ! command -v brew &>/dev/null; then
	/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
	eval "$(/opt/homebrew/bin/brew shellenv)"
fi
# --no-upgrade installs what is missing and leaves the rest alone. Without it
# every run upgrades everything outdated, over a hundred formulae at a time.
# It covers only the Brewfile's own entries, so the two variables stop an
# install of a new one from upgrading its dependencies and dependents too.
HOMEBREW_NO_INSTALL_UPGRADE=1 HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1 \
	brew bundle install --file=brew/Brewfile --no-upgrade
# Not in the Brewfile, because the main machine has them from outside Homebrew:
# a WezTerm built from source and fonts copied in by hand. brew bundle fails on
# an app or font it finds already there.
[[ -d /Applications/WezTerm.app ]] || brew install --cask wezterm@nightly
fonts=(~/Library/Fonts/SauceCodePro*(N))
(( $#fonts )) || brew install --cask font-sauce-code-pro-nerd-font
[[ -x ~/.local/bin/claude ]] || curl -fsSL https://claude.ai/install.sh | bash

# Stow folds a directory into a single symlink when it creates that directory
# itself. We want that one level down, so hooks/, references/ and themes/ each
# become a single link, but not for ~/.claude, which would put Claude Code's
# session state (600M+ of transcripts, history and caches) inside the checkout.
# Creating ~/.claude first stops the fold there and lets the leaves fold.
# CLAUDE.md is a file, so it links on its own either way.
mkdir -p ~/.claude
# Same for ~/.ssh on a new Mac: folded, the keys copied in after would land in
# the checkout.
mkdir -m 700 -p ~/.ssh

for d in *(/); stow -v -t ~/ -S $d

# After stow, so KEEP_ZSHRC finds the stowed .zshrc instead of writing one
# that the next stow would trip over.
[[ -d ~/.oh-my-zsh ]] ||
	RUNZSH=no KEEP_ZSHRC=yes sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
for p in zsh-autosuggestions zsh-syntax-highlighting; do
	[[ -d ~/.oh-my-zsh/custom/plugins/$p ]] ||
		git clone -q https://github.com/zsh-users/$p ~/.oh-my-zsh/custom/plugins/$p
done
# .zshenv sources ~/.cargo/env unconditionally.
[[ -f ~/.cargo/env ]] ||
	curl -fsSL https://sh.rustup.rs | sh -s -- -y --no-modify-path
. ~/.cargo/env
# plugins/ is gitignored, TPM included, so a fresh checkout has to fetch it.
[[ -d ~/.config/tmux/plugins/tpm ]] ||
	git clone -q https://github.com/tmux-plugins/tpm ~/.config/tmux/plugins/tpm
~/.config/tmux/plugins/tpm/bin/install_plugins
tmux source ~/.config/tmux/tmux.conf

# Yazi flavors are pinned in yazi/.config/yazi/package.toml but not committed,
# so a fresh checkout has a theme.toml naming a flavor that is not there yet.
ya pkg install

# LazyVim's rust extra drives rust-analyzer through rustaceanvim, which takes it
# from the toolchain rather than Mason so it stays in step with rustc. The catch
# is that ~/.cargo/bin/rust-analyzer is a rustup shim that exists whether or not
# the component behind it does, so a machine missing the component gives the
# editor a binary that launches and exits rather than one it can report missing.
command -v rustup &>/dev/null && rustup component add rust-analyzer

# Claude Code's settings.json is written by Claude Code itself, so it is merged
# into rather than stowed -- see the script for why a symlink there is unsafe.
~/.claude/hooks/install-hooks.sh
# The hook only sees turns that end after it exists, and a session parked on a
# question produces no more turns. Catch up the ones already stuck.
~/.claude/hooks/claude-waiting-backfill.sh

~/.config/srcsync/launchd/install.sh
# Runs the stowed ~/.sleep and ~/.wakeup, so srcsync publishes before the lid
# closes and applies on wake.
brew services start sleepwatcher

# Generate initial aerospace.toml (tile mode as default)
~/.config/aerospace/tile-mode/auto-config.aerospace.sh 2>/dev/null || true
