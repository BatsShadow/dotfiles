# Tile mode (rewrite) — design

App-driven, single-workspace tiling that coexists with workspace mode. Goal: lay
every app out on one tiled workspace and switch which app is *primary* with a
single keystroke, keep secondary apps visible, and stash/reclaim one window on
the secondary monitor — the most productive way possible.

Toggle between tile mode and workspace mode with **alt-shift-q** (unchanged key).

## Layout

```
   built-in (LEFT / secondary)        XDR (primary)
 ┌────────────────────────┐   ┌──────────────┬──────────────┐
 │                        │   │              │  stack  ▏     │  small, top
 │   single reference     │   │    MASTER    ├──────────────┤
 │       window           │   │              │  SECONDARY   │  big, bottom
 │   (0 or 1 window)      │   │              │              │
 └────────────────────────┘   └──────────────┴──────────────┘
```

- The XDR (primary) workspace `Tiles` holds three roles: **master** (big, left),
  **secondary** (big, bottom-right), and the **remaining stack** (small, top-right).
- The built-in monitor (physically on the **left**) hosts workspace `Tiles2`,
  a **capacity-1** reference slot (0 or 1 window).

**Single-monitor (undocked / built-in only):** the right side becomes a single
**accordion** column (`v_accordion`) instead of the weighted secondary-plus-stack
split — on the small laptop screen the weighted split shrinks the secondary too
much, so we keep one large secondary with the rest collapsed to accordion strips.
Dual-monitor (XDR) uses the weighted `v_tiles` split described below.

### How the layout is realized (robust, no fragile tree surgery)

The primary risk in the old tile mode was incremental `swap`/`join-with` under
AeroSpace normalization, which reshuffles unpredictably. The rewrite instead
**rebuilds the arrangement from scratch** on every change, which always converges:

1. `flatten-workspace-tree` — drop all nesting, everything becomes root siblings.
2. `aerospace layout v_tiles` — stack every window into one vertical column.
3. Order the column: small stack on top, **secondary last (bottom)**.
4. Focus the master → `aerospace move left` — pops master out into its own left
   tile. Result tree: `h_tiles[ master | v_tiles[ …stack…, secondary ] ]`.
5. `resize` the secondary taller and set the master width to the seeded default.

Verified on AeroSpace 0.21.2: steps 1–2 + `move left` deterministically produce
`master ∈ h_tiles`, `stack ∈ v_tiles`. `resize height/width` and `move down/up`
all succeed.

### Sizing

Master opens at a **reasonable default width** derived from the existing gap
configs (`split.gaps.toml` + the workspace-mode `*-windows.gaps.toml`
proportions) rather than an arbitrary number. Outer margins / inner gaps are
reused as the starting geometry (dropping the old 710px left-centering margin,
which no longer fits a left-anchored master). alt-R / alt-S tune from there.

## Promotion / rotation (the core interaction)

State file `.tile-master` tracks the current master window id.

**Promote app N to master** (app key, or reclaim from built-in):
- secondary := the *old* master (rotate down to the big bottom slot)
- old secondary rotates up into the small stack
- `.tile-master` := N
- run the relayout above

Pressing two app keys back and forth toggles the two apps between master and the
big secondary — the app you just left is always sitting right there, large.

## Keymap (tile mode)

Right hand — **app keys** (promote to master; monitor-aware): if the target app
lives on the built-in monitor, just **focus it there in place** instead of pulling
it over.

| Key | App |
|-----|-----|
| alt-U | WezTerm |
| alt-O | Arc (Browser) |
| alt-L | Arc / Gmail |
| alt-H | Slack |
| alt-Y | Arc / YouTube |
| alt-C | Calendar |
| alt-; | Discord |
| alt-Z | Zoom |

Left hand — **A R S T** (physical left-to-right):

| Key | Action | Mnemonic |
|-----|--------|----------|
| alt-A | Focus the **built-in** (far-left) monitor | leftmost key → leftmost screen |
| alt-R | **Shrink** master (split moves **left**) | left key → split left |
| alt-S | **Grow** master (split moves **right**) | right of R → split right |
| alt-T | Focus back to **primary** / master | rightmost → back to center |

Movement (unchanged, Colemak-DH): alt-M/N/E/I = focus left/down/up/right within
the XDR (master ↔ secondary ↔ stack).

**alt-shift-tab** — cross-monitor, depends on focus (asymmetric by design):
- Focused window on the **XDR** (master or secondary) → **swap** it with the one
  window on the built-in monitor (they trade places; built-in stays capacity-1).
  If built-in is empty, it's a one-way push and the vacated XDR slot refills from
  the stack.
- Focused window on the **built-in** → **no swap**: promote it to master (old
  master demotes to secondary, same rotate as an app key). Built-in becomes empty.
- **Single monitor** (undocked): no-op.

Service mode (alt-shift-quote) unchanged.

## Mode-toggle continuity (alt-shift-q)

- **workspace → tile:** the focused workspace's app becomes the master
  (relayout seeds `.tile-master` from the focused window).
- **tile → workspace:** land on the **master window's** resolved workspace
  (via `resolve-workspace.sh`) instead of the hardcoded `Terminal`.

## Syntax migration (AeroSpace v0.21 "v2")

Two parts:

**1. `config-version = 2`** — this is the formal "version 2." `reload-config`
warns that `config-version = 1` is outdated. Opting into v2 changes exactly one
thing: `persistent-workspaces` stops being inferred from keybinding right-hand
sides and defaults to `[]`. To preserve behavior we add `config-version = 2` plus
an explicit `persistent-workspaces` list (in both `globals.toml` files and the
generated `aerospace.toml`).

**2. `on-window-detected` `test` DSL** — the soft-deprecated dot-notation matchers
are converted to the `test` DSL across `aerospace.toml`, `tile-mode/modes.toml`,
`workspace-mode/modes.toml`:

```toml
# legacy
if.app-id = "company.thebrowser.Browser"
if.window-title-regex-substring = "Gmail"
# v2 (&& for AND, ~= is case-insensitive regex-substring)
if = 'test %{app-bundle-id} = company.thebrowser.Browser && test %{window-title} ~= Gmail'
```

Everything else (gaps arrays, mode bindings, `resize smart`, `swap`, `move`,
`move-workspace-to-monitor`, `workspace-to-monitor-force-assignment`, layout
commands) is already 0.21-current.

## Files

- `lib.sh` — shared helpers + state (`.tile-master`, `.tile-master-width`).
- `relayout.sh` — idempotent rebuild of the layout (dual: weighted stack; single: accordion).
- `promote.sh` — promote a window to master (rotate old master → secondary).
- `app.sh` — app-key handler (launch / on-focus / focus-on-secondary / promote).
- `monitor-toggle.sh` — alt-shift-tab swap/promote across the built-in monitor.
- `focus-monitor.sh` — alt-A / alt-T cross-monitor focus.
- `resize-master.sh` — alt-R / alt-S master-split resize (persisted).
- `enter.sh` — gather windows + seed master when entering tile mode.
- `auto-config.aerospace.sh` — generate tile `aerospace.toml` + reload + enter.

Superseded (no longer wired): `split-focus.aerospace.sh`, `move-to-other-tiles.sh`.

## Verification status

Only the built-in display was connected during implementation.

**Verified live (single monitor):**
- config-version 2 + `test`-DSL migration reloads with zero warnings; windows intact.
- Tree construction: `flatten → layout v_tiles → move left` yields a flat
  `h_tiles[master | v_tiles[stack]]`; single-monitor yields one `h_accordion`.
- Full toggle round-trip: workspace→tile gathers all windows to `Tiles` and seeds
  master from the focused app; tile→workspace restores every window to its
  resolved workspace and lands on the master's workspace (continuity).
- Handlers: `promote` (master rotates), `resize-master` (persists), `focus-monitor`,
  `monitor-toggle` (no-ops on a single monitor).

**Needs docked (XDR) verification:**
- Exact geometry/proportions of the weighted master + big-secondary + small-stack
  split (`SECONDARY_HEIGHT`, `DEFAULT_MASTER_WIDTH` in `lib.sh` are starting
  guesses to tune with alt-R/alt-S).
- The cross-monitor `alt-shift-tab` swap (XDR-focused) and promote (built-in-focused).
- App-key monitor-awareness (focus-in-place when the app is on the built-in).

## Known pre-existing quirks (not introduced here)
- YouTube matching/restore relies on the Arc window title containing "YouTube";
  while a video plays the title is the video name, so it can resolve to Browser.
- `workspace-mode/auto-config.aerospace.sh` prints a harmless `--monitor is
  mandatory` error on a single monitor (empty `XDR_ID`); it recovers.
