# Tile mode UX redesign — Stage / Rail / Aux

*Design spec — 2026-07-12. Design only; no implementation here. Turned into an
implementation plan separately.*

This is a UX-level redesign of tile mode's **interaction model** (which keys do
what, and what moves when). It does **not** change the underlying geometry: the
XDR still shows a big primary area beside an accordion column, and the built-in
still hosts a single reference window. What changes is the *meaning of the keys*
and, crucially, **what causes the layout to mutate at all**. See `DESIGN.md` for
the geometry and `FLICKER-PLAN.md` for the flicker work this design builds on.

## The problem

Today's tile mode conflates two things that want to be separate:

- **Attention** — *where am I looking?*
- **Arrangement** — *how is the screen laid out?*

Every attention shift *is* an arrangement change. An app key
(`alt-o`, `alt-h`, …) both focuses an app **and** promotes it to master,
rebuilding the layout. Glancing at Slack and restructuring the workspace are the
same keystroke.

This conflation is the root cause of the entire flicker problem. The bulk of
what you do all day is "look at a different app," and today that always mutates
the tree. The deeper fix is not "make mutation cheaper" (the FLICKER-PLAN work)
but "**most of the time, don't mutate at all**."

Two further weaknesses fall out of the same root:

- **The rail order is unstable.** Promoting rotates the old master down and
  reshuffles the column, so you can never build muscle memory of "Gmail is the
  third window down." Position carries no meaning because it never holds still.
- **Cross-monitor movement is a blind toggle.** `alt-shift-tab` acts on whatever
  is focused with no explicit direction.

## Design principle

> **Attention is free and non-destructive. Arrangement is deliberate and rare.
> Nothing rearranges itself behind your back.**

One-liner for teaching it:

> *App keys move your eyes; the shifted app key moves a window; nothing moves on
> its own.*

## The model: three stable zones

Windows live in named places with **stable membership**. A window does not leave
its zone unless a deliberate arrangement verb moves it.

| Zone | Where | Holds | Role |
|------|-------|-------|------|
| **Stage** | XDR, big primary area (today's *master*) | 1 window | Primary work surface |
| **Rail** | XDR, the accordion column (today's *secondary + extras*) | ordered, **stable** list | Readable, one-key-away parking |
| **Aux** | built-in monitor (`Tiles2`) | exactly 1 window (or empty) | A single persistent reference |
| *Deck* | offscreen | running-but-unplaced apps | Summoned onto the Rail on demand |

The Rail is a real, **readable** pane, not a sliver: its front window is large
enough to use, and the rebalance keys widen it further when needed. This is why
no "dual-stage / side-by-side" concept is needed — the Rail *is* the second
pane.

The one hard change to zone semantics versus today: **the Rail is order-stable.**
Arranging never reshuffles it (see Stage-it below). Stable order is what makes
positional muscle memory possible.

## The verbs

Everything reduces to a small set of gestures. The modifier selects intent, so
each intent is a single press.

### Look — attention, never mutates layout

- **`alt-<app>`** — focus that app wherever it lives. If it is on the Rail, raise
  it to the readable Rail front. If on the Stage, focus the Stage. If on Aux,
  focus the built-in. Implemented purely as `aerospace focus` — the flicker-free,
  zero-layout-op path. **This is the ~90% case and it never touches the tree.**
- **`alt-m/n/e/i`** — directional focus (Colemak-DH: left/down/up/right).
  Up/down walk the Rail; left/right cross between Stage and Rail. Pure attention.
- **`alt-a`** — look at Aux (focus the built-in). *(Unchanged from today.)*
- **`alt-t`** — look at the Stage (focus the current Stage window). *(Unchanged.)*

If an app has no window, its Look key launches it (today's behavior). If it is
running but unplaced (Deck), its Look key brings it onto the Rail and focuses it.

### Rebalance — resize the split, still no staging

- **`alt-r` / `alt-s`** — shrink / grow the Stage width, i.e. widen / narrow the
  Rail. Reach for this to read a Rail app harder *without* staging it.
- **`alt-w` / `alt-f`** — narrow / widen the XDR outer gaps.

*(All unchanged from today; reframed as first-class attention tuning — the tool
you use to read the Rail, not a power-user afterthought.)*

### Stage it — the one deliberate arrangement verb

- **`alt-shift-<app>`** — swap that app onto the Stage. The displaced Stage
  window drops into the Rail slot the incoming window just vacated, so **Rail
  order is preserved**. **Focus follows to the staged app.**
- **`alt-shift-t`** — stage *the focused window* (the generic, attention-
  addressed form, for when you navigated by direction rather than by app). Focus
  follows trivially, since the focused window is the one that moves. Mnemonic
  pairs with `alt-t` = look at Stage.

Stage-it is the *rare*, intentional "make this my primary work surface" gesture,
and the **only** routine layout mutation in the whole model. It reuses the
promote machinery already built and hardened in `promote.sh` (the S3/S4
swap-left fast paths).

**Focus rule:** whenever a gesture designates a new *primary* surface (Stage-it,
Aux-pin), focus follows the window there. Rationale: staging means "and let me
work in it," so splitting it into stage-then-look would break the one-press
intent. This also matches `promote.sh`, which already focuses the new master.

### Aux — a single-slot, stateful stash

**`alt-shift-a`** toggles the one Aux slot:

- **Aux empty** → pin the focused window to Aux. **Focus follows** (the window
  you were on just moved; focus rides along).
- **Aux occupied** → return that Aux window to the Rail. **Focus stays put** on
  whatever you had focused.

Single occupancy is enforced for free: an occupied Aux always reads the press as
"evict first," so a second window can never land there.

The stay-put-on-evict behavior is deliberate and exists for exactly one reason —
the **swap idiom**. To replace what is in Aux: focused on the window you want
stashed, Aux already holding something → **press once** (evicts the old Aux
window to the Rail; your target stays focused) → **press again** (Aux is now
empty, so it pins your still-focused target). Two taps, no chasing focus.

This is a single, principled asymmetry for a concrete mechanical need — not a
general pattern. Stage-it does **not** copy it, because the per-app stage keys
are self-targeting and have no analogous two-tap idiom.

**Behavior change from today:** un-parking returns to the **Rail**, not the
Stage. Today reclaiming from the built-in promotes straight to master; here
staging is a separate, deliberate verb. `alt-shift-a` fully replaces the old
`alt-shift-tab` monitor-toggle.

### Manual arrangement (power layer, retained)

- **`alt-shift-m/n/e/i`** — directional swap. Now most useful for **reordering
  Rail items** (up/down) since Rail order is meaningful, and for manual
  Stage/Rail swaps across the boundary (left/right). Complements the zone verbs;
  not part of the primary flow.

## Keymap summary

| Intent | Key | Was |
|--------|-----|-----|
| Look at app | `alt-<app>` (u/o/l/h/;/y/c/z) | promote app to master |
| Look — directional | `alt-m/n/e/i` | focus (same) |
| Look at Aux | `alt-a` | focus built-in (same) |
| Look at Stage | `alt-t` | focus master (same) |
| Rebalance Stage/Rail | `alt-r/s` | resize master (same) |
| Rebalance gaps | `alt-w/f` | resize gaps (same) |
| Stage an app | `alt-shift-<app>` | **new** |
| Stage the focused window | `alt-shift-t` | **new** |
| Aux toggle (pin / evict) | `alt-shift-a` | **new** (replaces `alt-shift-tab`) |
| Reorder Rail / manual swap | `alt-shift-m/n/e/i` | swap (same, reframed) |
| Toggle workspace mode | `alt-shift-q` | same |
| Repair layout | `alt-0` | same |

Freed by this design: `alt-shift-tab` (was monitor-toggle) — removed or left as
an alias for `alt-shift-a`, TBD in the plan.

## State model

Zone membership is derivable from AeroSpace's own tree:

- **Stage** = the window under the root `h_tiles` (the `h_tiles` master).
- **Rail** = the `v_accordion` members on `Tiles`, in tree order.
- **Aux** = the occupant of `Tiles2` (0 or 1).

Because Look never mutates the tree and Stage-it is an order-preserving swap, the
Rail's tree order is naturally stable — AeroSpace maintains child order and
nothing scrambles it. This is expected to let the design **retire the
`.tile-master` / `.tile-secondary` scramble-repair state** (or reduce it to only
the accordion-front hint the swap fast-path needs). Exact retention is an
implementation decision for the plan.

## What is reused vs. what changes

**Reused largely as-is:**

- Geometry, gaps, and the accordion column (`DESIGN.md`, `split.gaps.toml`).
- `promote.sh`'s swap-left fast paths — these *become* the Stage-it
  implementation.
- Rebalance (`resize-master.sh`, `resize-gap.sh`) and directional focus/swap.
- Mode entry/exit (`enter.sh` seeding the last-focused app as the Stage window;
  `toggle-mode.sh`).

**Changes:**

- **`app.sh`** — Look keys stop promoting. They become pure focus/raise
  (launch-if-absent and summon-from-Deck preserved). A parallel Stage-it entry
  point drives `promote.sh` for the `alt-shift-<app>` keys.
- **`monitor-toggle.sh` → an Aux toggle** on `alt-shift-a` with the stateful
  pin/evict semantics above (evict → Rail, not Stage; focus asymmetry as
  specified).
- **`modes.toml`** — add `alt-shift-<app>` and `alt-shift-t`; repoint
  `alt-shift-a`; retire/alias `alt-shift-tab`.

## Non-goals / explicitly cut

- **Dual / split stage (side-by-side).** The readable Rail plus Rebalance covers
  it. Cut.
- **`alt-1..9` positional layer.** Directional keys suffice and the number row is
  awkward on this keyboard. Cut.
- **Explicit "demote Stage → Rail" key.** Handled implicitly by Stage-it's swap
  and by Aux evict; no dedicated key for now.

## Open questions for the plan

1. `alt-shift-tab`: remove, or keep as an alias of `alt-shift-a`?
2. How much of `.tile-master` / `.tile-secondary` can actually be retired versus
   kept as a front-hint for the swap fast-path?
3. Look-at-app when the app has **multiple** windows (e.g. Arc with several
   matches): cycle among them, or always raise the same/first match? (Today
   `app.sh` picks the first Rail match.)
