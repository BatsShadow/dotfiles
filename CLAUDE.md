# CLAUDE.md

macOS dotfiles under GNU Stow. Each top-level directory is a package mirroring
`$HOME`, so `zsh/.zshrc` becomes `~/.zshrc`. `./install.zsh` stows everything
and runs the post-stow steps. `stow -v -t ~/ -S <package>` does one.

## Read the header before you edit the script

Every non-obvious script here opens with a long comment: the mechanism, and the
measured fact that forced it. `live-sessions.sh`, `claude-continue.sh`,
`claude-waiting.sh` and `install-hooks.sh` are the ones that will bite you if
you skip it. Read the header, then extend it when your change invalidates it.

Write new scripts the same way. Say why, not what, and name the fact you
checked. Don't copy those explanations into this file.

## Traps

- **`~/.claude` is only partly stowed.** `hooks/`, `skills/` and `themes/` are;
  nothing else is. The rest is Claude Code's own state, 600M+ of transcripts
  and caches, and it must stay out of the repo. `install.zsh` pre-creates
  `~/.claude` so stow folds one level down instead of swallowing all of it.
  Each of the three is a single symlink, so a skill or theme written straight
  into `~/.claude/` lands in the repo with no re-stow.
- **`~/.claude/settings.json` is merged, never stowed.** Claude Code rewrites
  that file itself and would replace a symlink with a regular file.
  `hooks/install-hooks.sh` merges in the hook registrations and the active
  theme, idempotently.
- A new file in an already-stowed package needs `stow -R <package>` unless the
  package folded to a single symlink.
- `zsh/private.env` holds secrets and is not committed.
- Gitignored and refilled by `install.zsh`: tmux `plugins/` via TPM, yazi
  `flavors/` via `ya pkg install`. The one committed flavor,
  `yazi/.config/yazi/flavors/ayu-mirage.yazi`, is a hand port to the current
  schema that `ya pkg` would overwrite.

## Tests

`tmux/.config/tmux/tests/` and `claude/.claude/hooks/tests/`. Each file is a
standalone executable you run directly. The tmux tests drive a real tmux server
on a throwaway socket, because the design rests on facts about tmux that a stub
would assert into existence. Any shell script with a real decision in it gets a
test.

## Verify by reloading, not by assuming

- tmux: `tmux source ~/.config/tmux/tmux.conf`
- kanata: `fn+R` reloads `config.kbd` in place
- aerospace: `aerospace reload-config`
- zsh: `exec zsh`
- claude hooks: run the script by hand, or run its tests

## Conventions

- Shell is vi mode (`bindkey -v`) with the oh-my-zsh vi-mode plugin.
- `vi` is neovim with `NVIM_APPNAME=lazyvim`; `EDITOR=/opt/homebrew/bin/nvim`.
- `eza` replaces `ls`, `zoxide` replaces `cd`, tmux auto-starts in zsh.
- tmux prefix is `Ctrl+Space`.
- Theming is ayu: dark in neovim and wezterm, mirage in yazi. All three are
  local edits rather than stock copies, so don't swap one for an upstream
  version. Catppuccin came first and left remnants that still read as live,
  notably the `catppuccin/tmux` plugin loaded in `tmux.conf` and an entry in
  `lazy-lock.json`. Leftovers, not the theme.

## Git

Don't create a branch unless asked. Work here is one config edit at a time,
checked by reloading the thing you just edited. A branch wraps that loop in a
merge and a cleanup for a review that never comes. Work in the checkout.
Suggest a branch only for something that will sit unfinished across sessions.

Ask before committing. Ask before pushing. Branching is the only step this
section removes.
