# Tile mode — flicker / least-damage test plan

Goal: stop treating every operation as "flatten + rebuild from scratch." Instead,
for each **starting state** do the **fewest window-geometry changes** that reach
the canonical layout, and *measure* the result so "least flicker" is objective,
not a guess.

Status legend: ✅ verified with tools · 🧪 proposed, needs verification · ⚠️ known-fragile

**Implemented so far:** the debug trace mode (§3); the **S2 no-op**, **S3 swap**, and
**S4 swap** fast-paths in `promote.sh` (promoting *any* column window — the A↔B
toggle or a peeking extra — now moves 2 windows with no flatten, `F=2`); and the
**S8 accordion-eject** entry (stack scattered windows into a flat accordion, then
eject the master in one move — entry no longer explodes windows into a grid). The
eject primitive also replaced the flatten+pop-×N in the full rebuild. S9 (gap
debounce) remains future work.

---

## 1. What "flicker" actually is (objective metric)

Flicker = **windows whose on-screen frame changes** during an operation, weighted
by how far/large the change is. A window that keeps its exact frame does **not**
flicker even if the tree around it is rewritten; a window that moves or resizes
does. Z-order changes (which accordion window is "front") are a *visible* change
but cost no geometry move — a separate, cheaper category.

Objective score for a candidate op sequence:

```
F = Σ_windows [ frame_changed ? 1 : 0 ]            # primary: how many windows moved
A = Σ_windows | area_after − area_before |          # tiebreak: how much they moved
Z = number of windows whose z-order/front changed   # cheap category, track separately
```

Lower `F` (then `A`, then latency) wins. The theoretical floor for a promote is
`F = 2` (the incoming window takes the master slot; the old master drops into the
column) — everything else should be able to hold still.

---

## 2. Operation cost model (ranked)

| Operation | Windows it disturbs | Flicker | Why |
|-----------|--------------------|---------|-----|
| `reload-config` | **all** on the workspace | ★★★★★ | full re-render of every frame; the only way to change gaps |
| `flatten-workspace-tree` | **all** | ★★★★★ | equalizes everything, then the rebuild has to re-split it back |
| `move-node-to-workspace` | 1 (animates across screens) | ★★★☆ /win | unavoidable when a window truly lives elsewhere |
| `layout` change on a container | that container's children | ★★★ | children re-flow to the new layout |
| `move <dir>` | moved window + sibling reflow | ★★★ | **can flip root/container orientation → cascade** ("wide main") |
| `resize` | 1 window + its neighbor | ★★ | localized |
| `focus` **into/within accordion** | z-order only (front window changes) | ★ (Z) | no geometry move; changes which window is visible |
| `focus` tile→tile | highlight/z-order | ½ (Z) | no geometry move |
| `sleep` (settle) | none | — | latency only, no flicker |

**Golden rules that fall out of this:**

1. **Never `flatten` if we're already tiled.** Touch only the windows whose role changes.
2. **Prefer `focus` (z-order, cost Z) over `move` (geometry, cost ★★★)** whenever the geometry is already correct and only the *visible/front* window needs to change.
3. **`move` is the orientation hazard.** If a `move` could flip the root orientation ("wide main"), force the orientation first or avoid the move.
4. **`reload-config` at most once, never per app-switch.** Only gap changes need it.
5. Any sequence that ends by moving focus *out of* the accordion needs a **settle** before the final master focus (window-server z-order lag — see DESIGN.md step 7).

---

## 3. Measurement protocol (how we verify each candidate)

Tools (built this session, committed under `tools/`):

- **Z-order / frame snapshot** — `tools/frames.swift` (compiled to `tools/.frames-bin`,
  gitignored) reads real macOS z-order + frames via `CGWindowListCopyWindowInfo`.
  Front-to-back order = visible stacking; per-window `x/y/w/h` = geometry. Emits TSV
  `z <TAB> window-id <TAB> x y w h`, skipping windows < 120px.
- **Human-readable snapshot** — `tools/snapshot.sh` joins `frames-bin` z-order with
  `aerospace list-windows` (app-name, parent-container-layout, title) and annotates
  role (`MASTER` for h_tiles, `COL-FRONT` for the frontmost v_accordion window,
  `col-peek` for the rest), marking the focused window with `*`.
- **Trace mode** — set `TILE_TRACE=<file>` and every script logs a header
  (`CMD:`, timestamp, pid) plus a `snapshot.sh` dump after each labelled step, with
  wall-clock + Δ-since-start. This is the debug harness for the whole transition.
  Zero overhead when `TILE_TRACE` is unset. See `lib.sh` (`trace_begin`/`trace`).
- **Frame diff (`F`, `A`)** — snapshot frames *before* and *after* a candidate
  sequence; diff window-id→frame and count changed frames (awk over two dumps).
- **Tree adjacency** — `focus {up,down,left,right} --boundaries workspace
  --boundaries-action stop` and read `list-windows --focused` back. Reveals tree
  structure **without** the z-order contamination that a bare `focus` probe causes.
  Cheaper still: `%{window-parent-container-layout}` (see `lib.sh parent_layout`)
  distinguishes master (`h_tiles`) from column (`v_accordion`) with no focus at all.

**Two hard cautions (learned the hard way):**
- **Never** judge "which window is front" with a `focus` probe — focusing *changes*
  the front window. Always read front from `zorder.swift`.
- Run candidates at real speed (no delays between ops) — inserting an inspection
  between steps hides settle races. Measure only from snapshots taken at the end.

---

## 4. Canonical target state

Dual monitor (XDR primary):

```
h_tiles[ MASTER | v_accordion[ SECONDARY(top, front), extra, extra, … ] ]   focus = MASTER
```

Single monitor: `h_accordion[ all windows ]`, focus = master (front by focus).

---

## 5. Starting-state matrix

Each row: what the workspace looks like when the trigger fires → the least-damage
op order to reach canonical, the **floor** of windows that must move, and how it
compares to today's "always relayout."

### S0 — Empty `Tiles`, or target app not running
- **Trigger:** app key, nothing matches.
- **Ideal end:** app launches → `on-window-detected` drops it on `Tiles`.
- **Ops:** `launch` only. No relayout until the window actually appears.
- **Floor:** 0 existing windows move. **Flicker: none.**
- **Today:** same (app.sh case 1). ✅

### S1 — One window on `Tiles` (just the master), press a *different* running app
- **Ideal end:** new window joins as the secondary → `h_tiles[master | accordion[new]]`.
- **Ops (🧪):** move new window onto `Tiles` if needed → pop master left once →
  `v_accordion` on the column → focus new (front) → settle → focus master.
- **Floor: 2** (master shifts left a bit; new window placed).
- **Today:** full flatten+rebuild of 2 windows — already cheap, low priority.

### S2 — Already tiled, pressed app key of the **current master**  ✅ done
- **Ideal end:** nothing changes (or run `--on-focus` if defined).
- **Ops:** **NO-OP** (return early). Optionally re-assert focus on master.
- **Floor: 0. Flicker: none.**
- **Implemented:** `promote.sh` detects `NEW_MASTER == get_master` (target already on
  `Tiles`) and just re-focuses it, then exits — no relayout. Verified: trace writes a
  single `S2 no-op` snapshot with no geometry change.

### S3 — Already tiled, target = the **current secondary** (accordion's front)  ✅ done — the A↔B toggle
- **Ideal end:** the two swap roles → target becomes master, old master becomes
  the accordion's front/top child. **Extras never move.**
- **Floor: 2** (only master-slot ↔ front-of-column swap). Achieved.
- **What actually worked (verified):** `swap` **is** directional and *does* cross the
  accordion/master boundary when the acting window is the accordion's first child —
  because that child's tree-left neighbour IS the master. So the whole promote is:
  `focus target; swap left`. Target lands in the master slot; old master drops to the
  top/front of the accordion. No flatten, no move loop, no settle sleep.
- **Implemented:** `promote.sh` S3 branch, guarded on the canonical shape
  (`dual_monitor`, target `== get_secondary`, target parent `v_accordion`, old master
  parent `h_tiles`). After the swap it re-checks that the target's parent is now
  `h_tiles` (it crossed) before committing `set_master`/`set_secondary`; if the layout
  had drifted, it falls through to the rebuild. Verified: A↔B toggle goes S3 every
  press, `F=2`, one trace snapshot vs the rebuild's 8, extras untouched.
- **Earlier dead-end (kept for the record):** an *unfocused* accordion never reorders
  under `move`/`swap`, so the old master's *position* at the top of the column is set
  by the swap while it is still crossing, and its *front* z-slot is inherited from the
  focus the swap gives it — no separate focus-last dance needed on this path.

### S4 — Already tiled, target = an **extra** in the accordion (not the front)  ✅ done
- **Ideal end:** target → master; old master → accordion front; old secondary
  → an ordinary extra. Other extras hold still.
- **Floor: 2 geometry** (target out, old master in) **+ Z** (front child changes). Achieved.
- **What worked (verified):** the *same* `focus target; swap left` as S3 — a
  directional `swap left` crosses to the master from **any** column child, not just
  the front one (confirmed on three different extras). Difference from S3: after the
  swap the resulting front window is **not deterministic** for a non-front extra
  (two promotions left two different windows in front), so S4 sets it explicitly:
  `focus OLD_MASTER` → `sleep 0.25` (settle) → `focus NEW_MASTER`. That is the only
  cost over S3 (~0.5s vs ~0.18s); still `F=2`, no flatten.
- **Implemented:** unified with S3 in `promote.sh` — the guard no longer requires
  `target == .tile-secondary`; it accepts any window whose parent is `v_accordion`
  (old master `h_tiles`). `WAS_FRONT` (target `== .tile-secondary`) picks the snappy
  no-settle re-focus (S3) vs the explicit front-set (S4). Post-swap verification and
  rebuild fallback unchanged.

### S5 — Target on **another tiled workspace** (not `Tiles`, not built-in)
- **Ops:** `move-node-to-workspace … Tiles` (1 window animates in) → then S4.
- **Floor: 2 + 1 cross-workspace animation.**
- **Today:** promote already pulls it, then full rebuild — replace rebuild with S4.

### S6 — Target on the **built-in** (secondary) monitor
- **Ideal end:** focus it *in place* on the built-in; `Tiles` untouched.
- **Ops:** `workspace SECONDARY_WS` → `focus --window-id`.
- **Floor: 0 on Tiles. Flicker: none on the primary.**
- **Today:** app.sh case 3 already does this. ✅

### S7 — Target **not running** → launch
- **Ops:** launch → when `on-window-detected` fires, insert as S4 (append to column)
  rather than a full rebuild.
- **Floor:** 1 new window placed; extras hold.

### S8 — **Workspace mode → tile mode** (alt-shift-q / `enter.sh`)  ✅ done — accordion-eject
- Windows are scattered across app-workspaces and must gather. The old cost was the
  `relayout` rebuild (~7 layouts, flatten explodes all N into equal grid tiles).
- **What was wrong with the first attempt at incremental:** `move-node-to-workspace`
  inserts a window at **root level** next to the focused window, *never* nested into
  the accordion — verified: with `h_tiles[master | v_accordion[a,b]]`, moving each
  new window in (even with a column window focused) made it a new **root column**
  that shrank the master (704→469→352px). So the intuitive "master first, feed the
  rest into the stack" order cannot work: every arrival tiles beside the master.
  `join-with` re-nests but scrambles the column into mixed `v_tiles`/`h_accordion`
  nests and still shrinks-then-restores the master each time — also rejected.
- **What works — invert the order (stack first, eject last):** move the master in,
  force the root to `v_accordion`, then stack every other window into that accordion
  — in an accordion each arrival simply **overlaps full-screen**, so gathering
  causes **zero tiling reshuffle**. Then eject the master leftward in **one** `move
  left` (from a root `v_accordion` the master pops straight to `h_tiles[master |
  v_accordion[rest]]`, no equal-columns stage). `relayout` detects the tree is
  already a flat accordion (`all_in_accordion`) and **skips the flatten** entirely.
- **Measured (real WS→tile toggle, 6 windows):** entry now takes the path
  stack-accordion → *skip flatten* → eject → focus secondary → resize — **4 steps,
  no window ever tiled into a grid** — vs the old flatten + h_tiles + pop-×6 +
  reorder + convert. The same eject primitive now backs the already-tiled rebuild
  too (repair / promote fallback), replacing the pop-×N with a single move.

### S9 — **Gap change** (alt-W / alt-F)
- `reload-config` is unavoidable (no runtime gap command) → inherently ★★★★★.
- **Ops:** persist gap → `render_config` → `reload-config` → re-assert master width. **No relayout/flatten.**
- **Today:** exactly this (`resize-gap.sh`). ✅ — but the `reload` re-renders every
  window. Open question: can we debounce rapid alt-W/alt-F presses into one reload?

### S10 — **Width change** (alt-R / alt-S)
- **Ops:** `resize --window-id master width` only.
- **Floor: 2** (master + column neighbor reflow). **No relayout, no reload.**
- **Today:** exactly this (`resize-master.sh`). ✅

### S11 — **Repair** (alt-0)
- Explicit "fix it" → full flatten+rebuild is acceptable here (that's its job).

### S12 — **Single monitor** (undocked)
- Whole workspace is one `h_accordion`; promote = **focus** (cost Z, zero geometry).
- Already the cheapest path. Just ensure promote on single-monitor never `flatten`s
  when the set is unchanged — a bare `focus` suffices. (🧪 confirm.)

### S13 — **Cross-monitor swap** (alt-shift-tab)
- Focused XDR window ↔ the one built-in window: `F = 2` by nature. Ensure it swaps
  those two only and doesn't trigger a full relayout on either side. (🧪 confirm.)

---

## 6. Summary of proposed changes (ranked by value ÷ risk)

| # | Change | Value | Risk | State |
|---|--------|-------|------|-------|
| 1 | **S2 no-op**: app key == current master → return early | high | trivial | ✅ done |
| 4 | **S3 swap** promote without flatten (`F=2`, the A↔B toggle) | **highest** | med | ✅ done (`focus target; swap left`) |
| 5 | **S4** (promote an accordion *extra*) via same swap + explicit front-set | med | med | ✅ done (unified with S3) |
| 3 | **S8** accordion-eject entry (stack first, eject master last, skip flatten) | high | med | ✅ done |
| 2 | **S9 debounce** rapid gap presses into a single reload | med | low | needs design |
| 6 | Guard single-monitor/cross-monitor promotes from needless relayout | med | low | needs confirm |

The rebuild-from-scratch path stays as the **correctness fallback**: if a
pair-move candidate can't hold the canonical tree + z-order across, say, 20
trials, we keep the rebuild for that state rather than ship something fragile.

---

## 7. Open decisions (need your call)

- **Latency vs. flicker:** the settle `sleep` (~0.25s) trades a beat of latency for
  correct front-window. Keep it only on paths that move focus out of the accordion
  (promotes); width/gap paths don't need it. OK?
- **How aggressive on S3/S4?** If pair-move proves fragile, are you fine keeping the
  rebuild there (correct but flickery), or should we invest in a stable-structure
  design where master/secondary swap is a pure `focus` (would require the secondary
  to be a real tile, not accordion — the nested layout we discussed)?
- **Gap debounce (S9):** worth it, or do you rarely spam alt-W/alt-F?
