# Tile mode — flicker / least-damage test plan

Goal: stop treating every operation as "flatten + rebuild from scratch." Instead,
for each **starting state** do the **fewest window-geometry changes** that reach
the canonical layout, and *measure* the result so "least flicker" is objective,
not a guess.

Status legend: ✅ verified with tools · 🧪 proposed, needs verification · ⚠️ known-fragile

**Implemented so far:** the debug trace mode (§3), the **S2 no-op** and **S3 swap**
fast-paths in `promote.sh` (the A↔B toggle now moves 2 windows with no flatten and
no intermediate layouts — trace shows 1 snapshot vs the rebuild's 8). S4/S8 remain
future work.

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

### S4 — Already tiled, target = an **extra** in the accordion (not the front)
- **Ideal end:** target → master; old master → accordion front/top; old secondary
  → an ordinary extra. Other extras hold still.
- **Floor: 2 geometry** (target out, old master in) **+ Z** (front child changes).
- **Ops (🧪):** same pair-move as C3b for target↔master, then the front-of-column
  is set purely by **focus** (cost Z, no geometry) — focus old master last, settle,
  focus new master.
- **Today:** full flatten+rebuild.

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

### S8 — **Workspace mode → tile mode** (alt-shift-q / `enter.sh`)
- Inherent high cost: windows are scattered across app-workspaces and must gather.
- **Today:** pull *every* window to `Tiles` (even ones already there) → `relayout`
  (which then `flatten`s). Double disturbance.
- **Ops to test (🧪):**
  1. Only `move-node-to-workspace` windows **not already** on `Tiles` (skip no-ops).
  2. Build incrementally: place master first, then **append** each extra into the
     accordion (each append moves 1 window; already-placed ones stay) — avoid the
     mid-sequence `flatten` that equalizes everything before re-splitting.
- **Measure:** `F` for "flatten+rebuild" vs "incremental append" on a 5-window set.

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
| 2 | **S9 debounce** rapid gap presses into a single reload | med | low | needs design |
| 3 | **S8** skip already-on-`Tiles` moves; incremental append | high | med | needs test |
| 5 | **S4** (promote an accordion *extra*) via swap+focus, no flatten | med | med | needs test |
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
