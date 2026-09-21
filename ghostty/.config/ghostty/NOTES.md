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

Colour. `window-colorspace = display-p3` is set, and it does not make Ghostty
match wezterm. It overshoots, which is the point. Sampled from the status bar of
a side-by-side screenshot, sRGB-tagged:

| configured | wezterm | Ghostty |
| ---------- | ------- | ------- |
| `#59c2ff`  | `#59c2ff` | `#03c5ff` |
| `#95e6cb`  | `#95e6cb` | `#79e9ca` |
| `#f07178`  | `#f07178` | `#ff6774` |

wezterm paints the configured hex verbatim. Ghostty shows each value as though
it were a Display P3 triple, which lands on the third column, exact to the byte
on all three. More saturated than the palette asks for, and preferred, so it
stays. Drop the line to get wezterm's rendering back.

An earlier revision of this file had the two terminals swapped, claiming wezterm
was the one showing the palette as P3 and that this setting made them agree.
Neither is true.

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

Ligatures. wezterm scoped features per rule, `calt,liga` on the roman faces and
`calt,liga,ss01` on the italic ones, so `ss01` is the entire difference between
them. Ghostty's `font-feature` is global and the man page lists per-face
targeting as a future enhancement, so one of the two had to give. `ss01` is
dropped. It is Monaspace's equals and comparison group, measured as covering
`! # - / = ~`, and having it on globally put those ligatures into roman code
text where wezterm never had them. The cost is italic and bold-italic losing
them, which in practice is nvim comments and the oh-my-posh prompt.

For reference, `calt` is texture healing rather than ligatures here, covering
letters plus 243 non-ASCII inputs, and `liga` covers `! . / ; |`.

Two ways to get the italic ligatures back, if they turn out to be missed.

Patch the two roman faces so the global `ss01` becomes a no-op for them. The
tag appears exactly once in each file, one feature record, so renaming it to the
unregistered `ss00` is a four-byte overwrite that keeps the alphabetical order
the spec wants (`sinf` < `ss00` < `ss02`) and shifts no offsets. The faces are
brew casks, so the copies also need their own family name, and `NF` to `NL` is
the same byte length in every `name` record, which keeps that in-place too.

Or use the official frozen build for the italic pair, which bakes every
stylistic set in. It has no Nerd Font variant, but `font-codepoint-map` routes
the icon ranges to a face that does:

```
font-codepoint-map = U+E000-U+F8FF,U+F0000-U+FFFFD=Monaspace Argon NF
```

Frozen is not brew-managed, though. `font-monaspace` ships the static set, 210
artifacts and none of them frozen, so that route means a hand-managed 69MB
download and all ten stylistic sets rather than just `ss01`.

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
