# Tile mode (rewrite) — design

App-driven, single-workspace tiling that coexists with workspace mode. Goal: lay
every app out on one tiled workspace and switch which app is *primary* with a
single keystroke, keep the other apps visible, and stash/reclaim one window on
the secondary monitor — the most productive way possible.

Toggle between tile mode and workspace mode with **alt-shift-q** (unchanged key).

## Layout

```
   built-in (LEFT / secondary)        XDR (primary)
 ┌────────────────────────┐   ┌──────────────┬──────────────┐
 │                        │   │              │  SECONDARY    │  large (accordion
 │   single reference     │   │    MASTER    │  (top)        │  first child)
 │       window           │   │              ├──────────────┤
 │   (0 or 1 window)      │   │              │  …peek…       │  extras peek below
 └────────────────────────┘   └──────────────┴──────────────┘
```

- The XDR (primary) workspace `Tiles` holds two roles: **master** (big, left)
  and, on the right, an **accordion column** whose front window is the
  **secondary**: it is raised to the top of the column and focused last, so
  AeroSpace keeps drawing it on top even while the master holds focus. The
  remaining "extra" windows peek below it.
- The built-in monitor (physically on the **left**) hosts workspace `Tiles2`,
  a **capacity-1** reference slot (0 or 1 window).

### Why an accordion (not a weighted split)

An earlier version tiled the right column as a weighted `v_tiles` split
(secondary tall at the bottom, small stack above). That fails when the column
holds several windows: macOS enforces a minimum window height, so the squeezed
"stack" windows overflow and **occlude** the secondary. An accordion solves this
structurally — all extra windows are layered *behind* the front window and peek
by `accordion-padding`, so the secondary is always fully visible no matter how
many windows pile up. AeroSpace only ever shows **one peek per side**, so the
secondary's size is constant regardless of count (no need to scale the padding).

### How the layout is realized (robust, no fragile tree surgery)

`relayout.sh` rebuilds the arrangement from scratch on every change, which always
converges regardless of the starting tree:

1. `flatten-workspace-tree` — everything becomes root siblings.
2. `layout h_tiles` on the master — force the **root horizontal**. This is
   essential: from a vertical root, popping the master out only wraps it in an
   `h_tiles` *child* and the root stays vertical, so the master renders as a
   full-width bar ("wide main").
3. `move left` × N on the master — over-shoot past the edge. AeroSpace ejects it
   to the root's left and its orientation-alternation nests the remaining windows
   into a column on the right → `h_tiles[ master | v_tiles[…] ]`.
4. Raise the **secondary to the top** of the column *while it is still `v_tiles`*.
   This ordering step must happen **before** the accordion conversion: on 0.21.2
   neither `move` nor `swap` reorders accordion children (both are no-ops inside an
   accordion), whereas `move` reorders a `v_tiles` column normally. Being the
   first/top child fixes the secondary's *position* at the top of the column. A
   guarded focus-up loop raises it one slot while a window sits above it and stops
   the instant nothing does — reaching the top without ejecting/collapsing the tree.
5. `layout v_accordion` on a column window — convert the right column to a
   vertical accordion (the master is under the root `h_tiles`, so it is
   unaffected). The order set in step 4 is now frozen, secondary first.
6. Focus the **secondary last**. An accordion keeps drawing whichever of its
   windows was focused most recently *on top of the rest*, and — crucially — that
   z-order **survives** focus moving back out to the master (confirmed via
   CGWindowList). So the secondary is both at the top (step 4) *and* the frontmost,
   fully-visible window while the master is focused; the extras peek below it. This
   is why a single focus-into-the-accordion "pops it forward" — we just pre-seed
   that state.
7. After a short **settle delay** — the window server needs a beat to raise the
   secondary to the front after the rapid rebuild, otherwise the master-focus lands
   first and an extra window keeps the front slot — `resize` the master to its
   seeded width and focus it.

Verified on AeroSpace 0.21.2 (front-window behavior checked against CGWindowList
z-order, since a stray `focus` probe would itself change which window is on top).
The guarded focus-based loops (used for both the master pop-left and the
secondary-to-top) never over-shoot, which is what made the old unbounded
`move up/down` ejections collapse the tree.

### Sizing

- **Master width** (`DEFAULT_MASTER_WIDTH` = 1408) matches a single window in
  workspace mode on the XDR: logical width 3008 − `outer.left` 750 −
  `outer.right` 850 = 1408 points. The "main" window stays the same size across a
  tile↔workspace toggle. alt-R / alt-S tune it live (persisted).
- **Outer gaps** on the XDR default to `outer.left` = 375 / `outer.right` = 190,
  which left-shifts the master and gives the accordion room. alt-W / alt-F adjust
  them together (ratio preserved, clamped [0, 600]). AeroSpace has no runtime gap
  command, so these are placeholders in `split.gaps.toml` substituted by
  `render_config` (lib.sh) and applied with `reload-config`.
- **Accordion peek** is `accordion-padding` = 200 (globals.toml); a larger value
  makes the peek bigger and the secondary a little shorter.

**Single-monitor (undocked / built-in only):** the whole workspace is one
`h_accordion` — whichever window you focus is large, the rest peek. On the small
laptop screen this keeps the focused window usable instead of shrinking a
weighted split too far.

## Promotion / rotation (the core interaction)

State files `.tile-master` and `.tile-secondary` track the current master and the
accordion's front window (the just-demoted master).

**Promote app N to master** (`promote.sh`, run by an app key or a reclaim) takes
the cheapest of three paths (see FLICKER-PLAN.md for the flicker cost model):

- **S2 — N is already the master:** just re-focus it and exit. No relayout, no
  window moves (`F=0`). Guards against a full rebuild firing on a redundant keypress.
- **S3/S4 — N is any window in the accordion column:** `focus N; swap left`. A
  column window's tree-left neighbour *is* the master (the accordion has no
  horizontal siblings, so "left" escapes it), so a single directional `swap left`
  exchanges exactly those two — N into the master slot, old master into the column.
  Only 2 windows move (`F=2`); no flatten, no move loop. Guarded on the canonical
  shape (`dual_monitor`, N's parent `v_accordion`, old master's parent `h_tiles`)
  and verified *after* the swap by re-reading N's parent layout — if it didn't cross
  into `h_tiles` the layout had drifted, so it falls through to the rebuild. The old
  master must land as the column's **front** (visible) window; how depends on where
  N sat:
    - **S3 (N was the front child — the A↔B toggle):** old master drops into the
      vacated front slot automatically, so a bare re-focus of N suffices. Snappy, no
      settle (~0.18s).
    - **S4 (N was a peeking extra):** the resulting front is *not* deterministic
      (verified: two extra-promotions gave different front windows), so we
      explicitly `focus OLD_MASTER` → settle → `focus N` — the same focus-last +
      settle the rebuild uses (~0.5s).
  N is recognised as the front child by `.tile-secondary`.
- **full — otherwise** (N is coming from another workspace and didn't land in the
  column, or the tree has drifted): pull N onto `Tiles` if needed, secondary := the
  old master, and run the `relayout.sh` rebuild above.

Because the demoted master ends up at the front of the column (via the swap on
S3/S4, or steps 4 & 6 of the rebuild), it is the large/visible front window
immediately — even while the new master holds focus. Pressing two app keys back and
forth toggles the two apps between master and the big secondary through S3 every time
— no flatten, no flicker — and the app you just left is always sitting right there,
large. Promoting a third app that was peeking in the column takes the same cheap
swap (S4).

## Keymap (tile mode)

Right hand — **app keys** (promote to master; monitor-aware): if the target app
lives on the built-in monitor, just **focus it there in place** instead of pulling
it over. A second press while already focused runs the app's `--on-focus` action.

| Key | App | Second press |
|-----|-----|--------------|
| alt-U | WezTerm | — |
| alt-O | Arc (regular browser) | — |
| alt-L | Arc / Gmail or Messages | toggle Gmail ↔ Messages |
| alt-H | Slack | — |
| alt-Y | Arc / YouTube | re-select the YouTube tab |
| alt-C | Calendar | open calendar |
| alt-; | Discord | — |
| alt-Z | Zoom | — |

Arc has one window per role; app keys match by window title
(`--find-title` / `--exclude`). "Email" = Gmail **or** Messages, mirroring the
workspace-mode `resolve-workspace.sh` mapping.

Left hand — **A R S T** (physical left-to-right):

| Key | Action | Mnemonic |
|-----|--------|----------|
| alt-A | Focus the **built-in** (far-left) monitor | leftmost key → leftmost screen |
| alt-R | **Shrink** master (split moves **left**) | left key → split left |
| alt-S | **Grow** master (split moves **right**) | right of R → split right |
| alt-T | Focus back to **primary** / master | rightmost → back to center |

Gaps — **W / F**:

| Key | Action |
|-----|--------|
| alt-W | **Narrow** the XDR outer gaps (master shifts left, accordion widens) |
| alt-F | **Widen** the XDR outer gaps (master shifts right, accordion narrows) |

Two independent size knobs: **R/S** = master↔column split width, **W/F** = outer
gaps (both move together, ratio-preserved, within [0, 600]).

Movement (unchanged, Colemak-DH): alt-M/N/E/I = focus left/down/up/right within
the XDR (master ↔ accordion). alt-shift-M/N/E/I = swap in that direction.

**alt-shift-tab** — cross-monitor, depends on focus (asymmetric by design):
- Focused window on the **XDR** (master or in the accordion) → **swap** it with
  the one window on the built-in monitor (they trade places; built-in stays
  capacity-1). If built-in is empty, it's a one-way push.
- Focused window on the **built-in** → **no swap**: promote it to master (old
  master demotes into the accordion, same rotate as an app key).
- **Single monitor** (undocked): no-op.

Service mode (alt-shift-quote) unchanged.

## Mode-toggle continuity (alt-shift-q)

- **workspace → tile:** the focused workspace's app becomes the master
  (relayout seeds `.tile-master` from the focused window).
- **tile → workspace:** land on the **master window's** resolved workspace
  (via `resolve-workspace.sh`) instead of the hardcoded `Terminal`.

## Syntax migration (AeroSpace v0.21 "v2")

Two parts:

**1. `config-version = 2`** — the formal "version 2." `reload-config` warns that
`config-version = 1` is outdated. Opting into v2 changes exactly one thing:
`persistent-workspaces` stops being inferred from keybinding right-hand sides and
defaults to `[]`. To preserve behavior we add `config-version = 2` plus an
explicit `persistent-workspaces` list (in both `globals.toml` files and the
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

A no-`if` catch-all is now an error, so the catch-all uses `if = 'true'`.

## Debug trace mode

Every script logs its full transition when `TILE_TRACE` names a file:

```bash
TILE_TRACE=$CLAUDE_CODE_TMPDIR/tile.log ./promote.sh 255
```

Each script emits a header (`CMD:`, ms-precision timestamp, pid) via `trace_begin`,
then a labelled `trace` snapshot after each step: the whole `Tiles` workspace as
real macOS **z-order** + geometry + parent-container layout, with wall-clock time
and Δ-since-start. This makes a transition replayable step-by-step to hunt flicker
(watch which windows' frames change and when the front window settles). Overhead is
zero when `TILE_TRACE` is unset. Implemented in `lib.sh`; snapshots come from
`tools/frames.swift` (CGWindowList z-order, compiled to `.frames-bin`) joined with
`aerospace list-windows` by `tools/snapshot.sh`. Front-window facts must be read
this way, never via a `focus` probe (focusing changes which window is on top).

## Files

- `lib.sh` — shared helpers + state (`.tile-master`, `.tile-secondary`,
  `.tile-master-width`, `.tile-gap`), `render_config` (config generation with gap
  substitution), and the `trace`/`trace_begin` debug harness.
- `relayout.sh` — idempotent rebuild of the layout (dual: master + accordion;
  single: one `h_accordion`).
- `promote.sh` — promote a window to master; S2 no-op / S3 swap fast-paths, else
  full rebuild (rotate old master → secondary on top).
- `app.sh` — app-key handler (launch / on-focus / focus-on-secondary / promote).
- `resize-master.sh` — alt-R / alt-S master-split width (persisted).
- `resize-gap.sh` — alt-W / alt-F XDR outer-gap adjust (re-render + reload).
- `focus-monitor.sh` — alt-A / alt-T cross-monitor focus.
- `monitor-toggle.sh` — alt-shift-tab swap/promote across the built-in monitor.
- `enter.sh` — gather windows + seed master when entering tile mode (moves only
  windows not already on `Tiles`, then one relayout rebuild).
- `auto-config.aerospace.sh` — generate tile `aerospace.toml` + reload + enter.
- `tools/frames.swift`, `tools/snapshot.sh` — debug z-order/geometry snapshot.

## Known pre-existing quirks (not introduced here)
- YouTube matching/restore relies on the Arc window title containing "YouTube";
  while a video plays the title is the video name, so it can resolve to Browser.
- `workspace-mode/auto-config.aerospace.sh` prints a harmless `--monitor is
  mandatory` error on a single monitor (empty `XDR_ID`); it recovers.
