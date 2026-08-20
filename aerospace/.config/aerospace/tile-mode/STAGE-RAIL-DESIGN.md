# Tile mode UX redesign — Stage / Rail / Shelf / Aux

*Design spec — 2026-07-12. Design only; no implementation here. Turned into an
implementation plan separately.*

*Amended 2026-07-17 — added the **Shelf**, a fourth zone. Stage / Rail / Aux is
built and in use; the Shelf is **designed but not yet implemented**. Sections
below are marked where the Shelf changes them.*

This is a UX-level redesign of tile mode's **interaction model** (which keys do
what, and what moves when). Aside from the Shelf (which adds one optional,
opt-in split — see below), it does **not** change the underlying geometry: the
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

## The model: four stable zones

Windows live in named places with **stable membership**. A window does not leave
its zone unless a deliberate arrangement verb moves it.

| Zone | Where | Holds | Role |
|------|-------|-------|------|
| **Stage** | XDR, big primary area (today's *master*) | 1 window | Primary work surface |
| **Rail** | XDR, the accordion column (today's *secondary + extras*) | ordered, **stable** list | Readable, one-key-away parking |
| **Shelf** | XDR, strip below the Rail | exactly 1 window (or empty) | A persistent reference kept **visible and drivable** |
| **Aux** | built-in monitor (`Tiles2`) | exactly 1 window (or empty) | A single persistent reference |
| *Floating* | above the tiles | apps forced to float (Tuna, REW) | Incidental; ignored by all arrangement verbs |

Every window in tile mode is in exactly one of these: Stage, Rail, Shelf, Aux, or
floating. There is no hidden/offscreen state — `enter.sh` gathers every tiled
window onto `Tiles` (Stage or Rail) or `Tiles2` (Aux), and floaters just float.
Launching an app with no window (via a Look key) lands its new window on the
Rail through the existing `on-window-detected` rule.

**Shelf and Aux are siblings**: both are single-slot reference holders. They
differ only in *where you look* — Aux is peripheral (the built-in), Shelf is in
your main field of view under the Rail. Reach for the Shelf when a reference must
stay watchable **on the big screen**; reach for Aux to get it off the XDR
entirely.

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

If an app has no window, its Look key launches it (today's behavior); the new
window lands on the Rail. If an app has **several** matching windows, Look raises
the **first/nearest** match (today's behavior — no per-app cycling). To bring a
*specific* other window of that app to the Stage, Look to it, walk to the exact
window with the directional keys, then `alt-shift-t` (stage the focused window).

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
`alt-shift-tab` monitor-toggle, which is **removed** (not aliased).

**Workspace mode gets the same key.** In workspace mode `alt-shift-a` is
currently unbound; the cross-monitor action lives on `alt-shift-tab`
(`move-workspace-to-monitor --wrap-around next`). To keep one consistent
"send it to the other screen" gesture across both modes, that action moves to
`alt-shift-a` in workspace mode and `alt-shift-tab` is removed there too. The
behavior stays mode-appropriate — Aux pin/evict in tile mode, whole-workspace
move in workspace mode — but the finger and the intent are the same. (`alt-a`
in workspace mode keeps re-applying the auto-config layout, unchanged.)

### Shelf — a single-slot, *visible* parking strip

*(Added 2026-07-17. Not yet implemented.)*

The Shelf is for the window you want to **keep an eye on and keep driving** while
you work: a music player you glance at and tap play/pause on, a log tailing, a
timer, a doc you keep rechecking. Its membership is **ad-hoc** — it is empty
until you decide, in the moment, "I'd rather keep this visible for now."

**Why not just use the Rail?** The Rail is an accordion: only its front window is
fully readable, the rest peek. That is precisely wrong for "keep this visible" —
the moment you Look at any other Rail app, your music player is a peek strip. The
Shelf's defining property is that its window **stays fully visible no matter what
the Rail is doing**. That property is the entire reason the zone exists.

**Geometry.** Empty by default: the Rail owns the whole right column exactly as
today, so an unused Shelf costs **nothing**. Occupied, the right column splits:

```
h_tiles[ Stage | v_tiles[ v_accordion[Rail] | Shelf ] ]
```

The Stage keeps full height and is never touched by the Shelf.

**Capacity is 1**, enforced exactly the way Aux enforces it: shelving while
occupied evicts the incumbent back to the Rail first.

**`alt-shift-d`** — Shelve. One contextual key, mirroring the Aux toggle:

- **Focused on a normal window** → park it on the Shelf; any incumbent returns to
  the Rail. **Focus does not follow** — you parked it to watch it, not to work in
  it, so focus returns to the **Stage**.
- **Focused on the Shelf window** → un-shelve it back to the Rail. **Focus
  follows** — you are re-activating it.

**`alt-d`** — Look at the Shelf: focus the Shelf window in place. This is what
makes the Shelf **drivable** (play/pause, pick a track) rather than merely
decorative. Pure attention; never moves anything.

This obeys the existing focus rule rather than bending it: focus follows only
when a gesture designates a new *primary* surface (Stage-it, Aux-pin). Shelving
designates a *reference*, not a primary — so it does not follow. `alt-d` is the
deliberate way in, and it is one key.

**Free from the existing model:**

- An app's Look key (`alt-<app>`) focuses its window **in place** if it is on the
  Shelf — it will not yank it off (same rule as Aux-in-place).
- **Stage-it** (`alt-shift-<app>` / `alt-shift-t`) pulls a Shelf window onto the
  Stage; the Shelf empties and the Rail reclaims the column.
- A Shelf window that closes empties the Shelf; the Rail reclaims the column.

**`alt-x` / `alt-c` become contextual.** They keep meaning *"shorter / taller in
the right column"* and retarget to whichever vertical adjustment is actually
meaningful:

- **Shelf empty** → adjust the Rail accordion peek (today's behavior,
  `resize-accordion.sh`).
- **Shelf occupied** → adjust the Rail ↔ Shelf split height.

Accepted tradeoff: while the Shelf is up you cannot also nudge the accordion
peek. Peek is a set-once-and-forget value; Shelf height is the thing you actually
want to tune live when something is parked. This costs no new keys and nothing to
relearn.

### Manual arrangement (power layer, retained)

- **`alt-shift-m/n/e/i`** — directional swap. Now most useful for **reordering
  Rail items** (up/down) since Rail order is meaningful, and for manual
  Stage/Rail swaps across the boundary (left/right). Complements the zone verbs;
  not part of the primary flow.

## Keymap summary

| Intent | Key | Was |
|--------|-----|-----|
| Look at app | `alt-<app>` (u/o/l/h/;/y/k/`,`/`.`) | promote app to master |
| Look — directional | `alt-m/n/e/i` | focus (same) |
| Look at Aux | `alt-a` | focus built-in (same) |
| Look at Shelf | `alt-d` | **new** (Shelf) |
| Look at Stage | `alt-t` | focus master (same) |
| Rebalance Stage/Rail | `alt-r/s` | resize master (same) |
| Rebalance gaps | `alt-w/f` | resize gaps (same) |
| Right-column vertical size | `alt-x/c` | accordion peek — **now contextual** (peek, or Rail↔Shelf split when Shelf occupied) |
| Stage an app | `alt-shift-<app>` | **new** |
| Stage the focused window | `alt-shift-t` | **new** |
| Aux toggle (pin / evict) | `alt-shift-a` | **new** (was `alt-shift-tab`, removed) |
| Shelve / un-shelve | `alt-shift-d` | **new** (Shelf) |
| Reorder Rail / manual swap | `alt-shift-m/n/e/i` | swap (same, reframed) |
| Toggle workspace mode | `alt-shift-q` | same |
| Fix screen (fold strays into Rail) | `alt-v` | **new** |
| Repair layout | `alt-0` | same |

`alt-d` / `alt-shift-d` deliberately mirror `alt-a` / `alt-shift-a` (Aux): the
two single-slot reference zones sit on neighboring keys with identical
Look / toggle shapes. `d` is free since Calendar moved to `k`.

`alt-shift-tab` (was monitor-toggle) is **removed** in both tile mode and
workspace mode; its cross-monitor role moves to `alt-shift-a`.

### The hand rule

`alt` is a home-row mod on **left-`r`** and **right-`i`**, so every binding wants
to be an *opposite-hand* chord. That forces a split, and the keymap should hold
to it:

> **Right hand = apps. Left hand = zones and layout.**

Apps (`u o l h ; y k , . j`) are all right-hand, held with **left-`r`** alt. Zone
and layout controls (`a` Aux, `t` Stage, `d` Shelf, `r`/`s` rebalance, `w`/`f`
gaps, `x`/`c` right-column size, `v` fix-screen) are all left-hand, held with
**right-`i`** alt.

This is why **Zoom moved from `alt-z` to the bottom row** *(2026-07-17)*: `z` is
the left pinky in Colemak-DH, so `alt-z` meant holding alt with left-ring and
reaching with left-pinky on the **same hand** — the only app key that broke the
rule, and it felt like it. **Safari** joined it, extending the bottom-row app
run: `k` Calendar, `h` Slack, `,` Safari, `.` Zoom.

*(2026-08-20: `,` and `.` swapped — Safari took comma, Zoom took period. Safari
is reached far more often, and comma is the easier of the two.)*

Known remaining exception: **`alt-p`** (Arc's PRs tab) is left-hand (`p` is
left-ring, top row). It is an app *action* rather than an app key, so the reach
matters less. There is no longer a spare key to move it to — see below.

**Workspace mode mirrors both keys** so the two modes never disagree about what a
key means: `,` = Safari, `.` = Zoom in both. Workspace mode's model is one app per
workspace, so this gave Zoom and Safari their own **`Zoom`** and **`Safari`**
workspaces (previously they were filed into `Slack` and `Browser` by
`on-window-detected`). `alt-shift-,` / `alt-shift-.` move a window there, matching
every other workspace-mode app key.

### `alt-j` — Poker, and the last free right-hand key

*(2026-08-20.)* ClubWPT Gold took **`alt-j`** with a **`Poker`** workspace. `j`
is the Colemak-DH top-row index finger (QWERTY-`y` position) and was the only
unbound right-hand letter left, so the hand rule survives intact — but it was
also the last one. The right hand is now full:

| Row | Keys |
|---|---|
| Top | `j` Poker · `l` Email · `u` Terminal · `y` YouTube · `;` Discord |
| Home | `m`/`n`/`e`/`i` focus · `o` Browser |
| Bottom | `k` Calendar · `h` Slack · `,` Safari · `.` Zoom · `/` layout toggles |

The only unbound right-hand keys remaining are `'` (whose shift partner is
already service mode, so it gets no move/stage sibling) and the brackets. A
tenth app key means either taking one of those or retiring an existing one.

### Zoom's key cannot launch Zoom

*(2026-08-20.)* `alt-.` passes **`--no-launch`** to both `dispatch.sh` and
`tile-mode/app.sh`. Zoom is an app you are *summoned by* — a meeting link opens
it — never one you go and start yourself, and a stray keypress that boots Zoom
in the background is pure noise.

The two halves are deliberately separate:

- The **`on-window-detected`** rule still routes `us.zoom.xos` to the `Zoom`
  workspace. Whenever Zoom does open a window, it lands where it belongs.
- The **key** only ever navigates. In workspace mode it still makes the trip to
  the (empty) `Zoom` workspace; in tile mode there is nothing to focus, so it is
  inert.

`--no-launch` is a general flag, not a Zoom special case — any app that should
only ever be opened by something else can take it.

### Layout toggles are disabled in tile mode

*(2026-07-17.)* `alt-slash` (`layout tiles accordion`) and `layout horizontal
vertical` are stock-AeroSpace bindings that mutate the container layout
directly — flipping the Rail's `v_accordion` to `v_tiles`, or the root's
orientation. In tile mode they can only **break the canonical Stage | Rail
tree**, leaving you to repair it with `alt-V` / `alt-0`. They are footguns here
and are bound to `[]`.

They remain in **workspace mode**, where free-form tiling makes them meaningful:
`alt-slash` = tiles/accordion, and `layout horizontal vertical` moved from
`alt-comma` to **`alt-shift-slash`** — putting both toggles on slash and freeing
`alt-comma` so the two modes don't disagree about what comma means.

## State model

Zone membership is derivable from AeroSpace's own tree:

- **Stage** = the window under the root `h_tiles` (the `h_tiles` master).
- **Rail** = the `v_accordion` members on `Tiles`, in tree order.
- **Shelf** = the lone `v_tiles` member of the right column on `Tiles` (0 or 1) —
  i.e. the child of the right column that is *not* the Rail accordion.
- **Aux** = the occupant of `Tiles2` (0 or 1).

The Shelf stays derivable like the rest, with one wrinkle: **`relayout.sh`
flattens the tree**, which destroys the evidence. It must therefore capture the
Shelf occupant *before* flattening and restore it after. Whether that capture can
stay transient or needs a durable `.tile-shelf` hint (to survive mode toggles and
restarts) is an implementation decision — see open questions.

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
  (launch-if-absent preserved; first/nearest match). A parallel Stage-it entry
  point drives `promote.sh` for the `alt-shift-<app>` keys.
- **`monitor-toggle.sh` → an Aux toggle** on `alt-shift-a` with the stateful
  pin/evict semantics above (evict → Rail, not Stage; focus asymmetry as
  specified).
- **`modes.toml`** (tile mode) — add `alt-shift-<app>` and `alt-shift-t`;
  repoint `alt-shift-a` to the Aux toggle; remove `alt-shift-tab`.
- **`workspace-mode/modes.toml`** — move `move-workspace-to-monitor
  --wrap-around next` from `alt-shift-tab` to `alt-shift-a`; remove
  `alt-shift-tab`.

**Changes for the Shelf** *(2026-07-17, not yet implemented)*:

- **New `shelf-toggle.sh`** — close sibling of `aux-toggle.sh` (single slot,
  evict-incumbent, contextual un-shelve). The Aux toggle is the template.
- **`relayout.sh`** — capture the Shelf occupant before `flatten-workspace-tree`,
  and rebuild the right column as `v_tiles[ v_accordion[Rail] | Shelf ]` when
  occupied (today it always builds a bare `v_accordion`). This is the one real
  cost of the Shelf: a second structural step on rebuild, and therefore some added
  flicker surface — but only while the Shelf is in use.
- **⚠️ `fix-screen.sh`** — its stray rule is "a `Tiles` window whose parent
  container is not an accordion and is not the master." A Shelf window's parent is
  `v_tiles`, so **today's rule would classify the Shelf as a stray and fold it
  into the Rail** on the next `alt-v`. The rule must exempt the Shelf occupant.
  Same care applies to anything else that reasons about "root-level" windows.
- **`app.sh`** — Look focuses a Shelf resident **in place** (extend the existing
  Aux-in-place branch); Stage-it pulls it off the Shelf.
- **`resize-accordion.sh`** — front it with a contextual dispatch: peek when the
  Shelf is empty, Rail↔Shelf split height when occupied.
- **`modes.toml`** (tile mode) — add `alt-d` / `alt-shift-d`; repoint `alt-x/c` at
  the contextual resize.

## Non-goals / explicitly cut

- **Dual / split stage (side-by-side).** The readable Rail plus Rebalance covers
  it. Cut.
- **`alt-1..9` positional layer.** Directional keys suffice and the number row is
  awkward on this keyboard. Cut.
- **Explicit "demote Stage → Rail" key.** Handled implicitly by Stage-it's swap
  and by Aux evict; no dedicated key for now.

## Open questions for the plan

1. How much of `.tile-master` / `.tile-secondary` can actually be retired versus
   kept as a front-hint for the swap fast-path?
2. **Shelf durability.** Can the Shelf occupant stay purely tree-derived
   (captured/restored around `relayout.sh`'s flatten), or does it need a durable
   `.tile-shelf` hint to survive a mode toggle or an AeroSpace restart? Related:
   should a tile→workspace→tile round-trip *preserve* the Shelf, or is resetting
   it to empty acceptable (and simpler)? Default lean: reset is acceptable.
3. **Shelf height default.** What starting fraction of the right column should the
   Shelf take (and its min/max), by analogy to `DEFAULT_ACCORDION_PADDING`? A
   music player wants little; a log tail wants more.
