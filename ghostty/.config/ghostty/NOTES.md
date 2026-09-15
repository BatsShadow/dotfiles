# Ghostty migration status

Trialling Ghostty as a replacement for wezterm. Notes for picking this up cold.
Written 2026-09-13, revised 2026-09-15 against Ghostty 1.3.1.

## Where things are

- Config: `~/dotfiles/ghostty/.config/ghostty/config.ghostty`
- Stow package: `ghostty/`, picked up automatically by `install.zsh`, which
  loops over every top-level directory. No installer change needed.
- Source of truth for the translation: `~/dotfiles/wezterm/.config/wezterm/`

## Status

Ghostty 1.3.1 is installed and this config is live. `config.ghostty` is one of
the two filenames Ghostty reads on its own, alongside plain `config`, so it
needs no rename and no `config-file` line pointing at it. An earlier revision of
this file claimed the opposite and was wrong.

Both config directories load additively, `$XDG_CONFIG_HOME/ghostty/` and
`~/Library/Application Support/com.mitchellh.ghostty/`. Only the stowed one is
in use.

`ghostty +validate-config` passes. Worth knowing while editing:

```
ghostty +show-config --changes-only
ghostty +show-face --font-family='Monaspace Xenon NF' --style=ExtraBold
ghostty +list-fonts | grep Monaspace
```

`+show-face` did not honour `--config-file` in testing, so name the family and
style on the command line rather than expecting it to read the config.

## Settled

Colour. Everything read washed out beside wezterm because wezterm hands sRGB hex
straight to the display without converting, so the ayu palette is effectively
shown as Display P3. Ghostty converts by default and lands on the duller,
technically correct colour. `window-colorspace = display-p3` matches wezterm.
Confirmed by sampling pixels from a screenshot of each and running the P3 to
sRGB conversion, which agreed to the byte.

Font styles. Three of the four style strings guessed from the docs were right.
`Black` is not a style Xenon NF advertises and is now `ExtraBold`, checked with
`+show-face`. `Medium Italic` is gone for a different reason, below.

Prompt italics. The four Monaspace faces are a font selector rather than a
weight ramp, so `font-style-bold-italic` is `Medium` and not `Medium Italic`.
The oh-my-posh prompt wraps 15 segments in `<b><i>` to pick Krypton and is not
asking for slanted text, and wezterm's matching rule names Krypton at weight
Medium with no style. Naming the upright face is not enough on its own:
`font-synthetic-style` defaults to `bold,italic,bold-italic` and Ghostty skews
the face itself, which is how the slant survived. It has to be `no-bold-italic`,
since the docs warn that disabling italic alone leaves the slant in the
bold-italic style.

Keys. All of them work, `\x00` included, so the old `prefix2 C-b` fallback is
unnecessary. `digit_0` and `zero` are both real key names and both are needed.
Ghostty registers `goto_tab` under the W3C physical-key names, so rebinding only
the word-name spelling leaves the default live and both fire.

Padding. `window-padding-y` does take a `top,bottom` pair. Currently `5,0`.

Glyph sizing. Ghostty scales nerd font icons to the cell and wezterm draws them
at natural size, so the tmux status bar's busy icon came out twice the size it
is in wezterm. `adjust-icon-height` cannot reach a glyph whose width is what
binds, since it only lowers a height maximum. Fixed on the tmux side by using
ordinary Unicode, which is never scaled.

## Still open

`alpha-blending` is `native`. The reasoning that originally put a value here
argued from a premise that no longer holds now the colourspace is `display-p3`,
so `native`, `linear` and `linear-corrected` want comparing again on the same
nvim buffer.

`font-feature = ss01` is global. Ghostty has no way to scope a feature to one
face, so the alternate cursive forms wanted on Argon and Krypton also land on
Neon and Xenon. Look at a roman `a` and `f` with it on and off.

`background-blur = 30` is Ghostty's own blur. macOS 26 also accepts
`macos-glass-regular` and `macos-glass-clear`, which draw through
`NSGlassEffectView`. Tried once and reverted; worth another look.

The wait glyph on the status bar is still a nerd font icon carrying the same
scaling exposure the busy glyph had. One line in
`tmux/.config/tmux-powerline/segments/claude/glyphs.sh` if it starts to show.

Five places outside this package name wezterm as the terminal to raise: three in
`aerospace/`, and `TERM_APP` plus `goto.sh` under tmux-powerline. They only need
changing if Ghostty becomes the default.

## Deliberately dropped

Ghostty has no scripting layer. The wezterm config used
`pane:get_foreground_process_name()` to send tmux keys only when tmux was the
foreground process. Every binding here fires unconditionally, which is fine
because tmux is always running.

The concrete loss is cmd-K, which in wezterm fell back to clearing wezterm's own
scrollback outside tmux. Here it always sends prefix C-k.
