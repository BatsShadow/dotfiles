# dotfiles
GNU Stow dotfiles

## A new Mac

Two things can't come from this repo and have to be copied over by hand,
before `install.zsh` runs:

- into `~/.ssh`, the GitHub keys `~/.ssh/new_id_ed25519` (BatsShadow) and
  `~/.ssh/swebber_upngopay_github_id` (company). srcsync's LaunchAgent, if you
  install it, pushes with them and can't answer a passphrase prompt.
- `zsh/private.env`, which holds secrets and isn't committed.

Then:

```sh
git clone https://github.com/BatsShadow/dotfiles ~/dotfiles
cp /path/to/private.env ~/dotfiles/zsh/
cd ~/dotfiles && ./install.zsh
git remote set-url origin git@github.com-batsshadow:BatsShadow/dotfiles.git
```

`install.zsh` installs Homebrew if it's missing, then everything in
`brew/Brewfile`, WezTerm, the SauceCodePro font and Claude Code, stows every
package but srcsync, and sets up oh-my-zsh, rustup, tmux plugins and the
Claude hooks. It skips anything already there, so it's safe to run again. The
clone has to be at `~/dotfiles`, because `.zshenv` reads `private.env` from
there.

On a machine that already has the checkout, `git pull && ./install.zsh` does
the same.

stow refuses to replace a file it didn't create. If it names one, move that
file aside and run `install.zsh` again.

kanata runs as root and is installed by hand with
`kanata/.config/kanata/install.sh`.

## srcsync

srcsync runs in the background once installed, so `install.zsh` leaves it out.
It has its own installer:

```sh
./install-srcsync.zsh       # stow it, start the LaunchAgent and sleepwatcher, add the Claude hook
./install-srcsync.zsh off   # stop all of that; the code and ~/.local/state/srcsync stay
```

While `srcsync/.config/srcsync/config` says `auto on`, the LaunchAgent applies
the other machine's work within three minutes. With `auto off` its triggers
only write to `~/.local/state/srcsync/auto.log`. To take it now either way:

```sh
~/.config/srcsync/srcsync.sh apply
```

Each machine publishes under its own id, kept in
`~/.local/state/srcsync/host`. Check that the two machines' ids differ.
`srcsync/.config/srcsync/DESIGN.md` has the rest.
