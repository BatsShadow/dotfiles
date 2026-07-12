#!/usr/bin/env bash
# Shared helpers + state for the rewritten tile mode.
# Sourced by relayout.sh, promote.sh, app.sh, monitor-toggle.sh, etc.

TILE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AERO_DIR="$(cd "$TILE_DIR/.." && pwd)"

# --- Workspaces ---
PRIMARY_WS="Tiles"     # primary tiling workspace (lands on the main / XDR monitor)
SECONDARY_WS="Tiles2"  # capacity-1 reference slot (pinned to the built-in monitor)

# --- State files (gitignored) ---
MASTER_FILE="$TILE_DIR/.tile-master"        # window-id of the current master
SECONDARY_FILE="$TILE_DIR/.tile-secondary"  # window-id of the accordion's top/front window
WIDTH_FILE="$TILE_DIR/.tile-master-width"   # master width in logical px (tunable)
GAP_FILE="$TILE_DIR/.tile-gap"              # XDR outer LEFT gap in px (alt-W/alt-F)

# --- Tunables (starting geometry; alt-R/alt-S adjust the width live) ---
# DEFAULT_MASTER_WIDTH matches the width of a single window in workspace mode on
# the XDR: logical width 3008 − outer.left 750 − outer.right 850 = 1408 points
# (see workspace-mode/one-window.gaps.toml). Keeps the "main" window the same
# size across a tile↔workspace toggle. alt-R/alt-S tune from here.
DEFAULT_MASTER_WIDTH=1408
MIN_MASTER_WIDTH=500
WIDTH_STEP=80               # px per alt-R / alt-S press

# --- Read an array portably (macOS ships bash 3.2, no mapfile) ---
# usage: read_lines ARRAYNAME < <(command)
read_lines() {
  local __name="$1" __line
  eval "$__name=()"
  while IFS= read -r __line; do
    [ -n "$__line" ] && eval "$__name+=(\"\$__line\")"
  done
}

# --- Monitors ---
monitor_count() { aerospace list-monitors --count; }
xdr_id()     { aerospace list-monitors --format '%{monitor-id} %{monitor-name}' | grep -i 'XDR'      | awk '{print $1}' | head -n1; }
builtin_id() { aerospace list-monitors --format '%{monitor-id} %{monitor-name}' | grep -i 'built-in' | awk '{print $1}' | head -n1; }
dual_monitor() { [ "$(monitor_count)" -ge 2 ]; }

# --- Windows ---
# Tileable (non-floating) window-ids on the primary workspace, in tree order.
tiles_windows() {
  aerospace list-windows --workspace "$PRIMARY_WS" --json \
    --format '%{window-id} %{window-parent-container-layout}' 2>/dev/null \
  | jq -r '.[] | select(.["window-parent-container-layout"] != "floating") | .["window-id"]'
}
secondary_windows() {
  aerospace list-windows --workspace "$SECONDARY_WS" --format '%{window-id}' 2>/dev/null
}
focused_window() { aerospace list-windows --focused --format '%{window-id}' 2>/dev/null; }

window_exists() { aerospace list-windows --all --format '%{window-id}' 2>/dev/null | grep -qx "$1"; }
window_workspace() {
  aerospace list-windows --all --format '%{window-id}%{tab}%{workspace}' 2>/dev/null \
    | awk -F'\t' -v id="$1" '$1==id{print $2; exit}'
}

# --- Master / secondary state ---
get_master() { cat "$MASTER_FILE" 2>/dev/null; }
set_master() { echo "$1" > "$MASTER_FILE"; }

# The secondary is the accordion's top/front window (the just-demoted master). It
# is tracked so promote can take the cheap "swap with master" fast-path when the
# target you press is already the secondary (the A<->B toggle). Maintained by both
# relayout (rebuild) and the swap fast-path so it always names the top col window.
get_secondary() { cat "$SECONDARY_FILE" 2>/dev/null; }
set_secondary() { echo "$1" > "$SECONDARY_FILE"; }

# Parent-container layout of a window on the primary workspace (h_tiles for the
# master, v_accordion for a column window). Cheap and has no focus side effects.
parent_layout() {
  aerospace list-windows --workspace "$PRIMARY_WS" \
    --format '%{window-id} %{window-parent-container-layout}' 2>/dev/null \
  | awk -v id="$1" '$1==id{print $2; exit}'
}

# True when every non-floating window on the primary workspace is in a v_accordion
# container — i.e. the tree is already a single flat vertical accordion, so the
# eject-based relayout can skip the flatten "explode into equal tiles" step. A
# canonical tiled layout (master under the root h_tiles) is NOT all-accordion, so
# this correctly returns false there and the flatten still runs.
all_in_accordion() {
  local layouts
  layouts="$(aerospace list-windows --workspace "$PRIMARY_WS" \
    --format '%{window-parent-container-layout}' 2>/dev/null | grep -v '^floating$')"
  [ -n "$layouts" ] && ! grep -qv '^v_accordion$' <<< "$layouts"
}

get_width() { local w; w="$(cat "$WIDTH_FILE" 2>/dev/null)"; echo "${w:-$DEFAULT_MASTER_WIDTH}"; }
set_width() { echo "$1" > "$WIDTH_FILE"; }

# --- XDR outer-gap state (alt-W narrows / alt-F widens) ---
# Only the LEFT gap is stored; the RIGHT gap is derived so the two keep the same
# ratio as the defaults (375:190). Both scale together within [GAP_MIN, GAP_MAX];
# aerospace has no runtime gap command, so a change means re-rendering the config
# and reload-config (see resize-gap.sh).
DEFAULT_GAP_LEFT=375
DEFAULT_GAP_RIGHT=190
GAP_MIN=0
GAP_MAX=600
GAP_STEP=75

get_gap_left()  { local g; g="$(cat "$GAP_FILE" 2>/dev/null)"; echo "${g:-$DEFAULT_GAP_LEFT}"; }
set_gap_left()  { echo "$1" > "$GAP_FILE"; }
# right gap derived from left, preserving the default ratio (rounded)
gap_right_for() { echo $(( ($1 * DEFAULT_GAP_RIGHT + DEFAULT_GAP_LEFT / 2) / DEFAULT_GAP_LEFT )); }

# Emit the full tile-mode aerospace.toml (globals + gaps + modes) with the XDR
# gap placeholders substituted for the current values. Single source of truth for
# both auto-config (mode activation) and resize-gap (live gap tweak).
render_config() {
  local L R
  L="$(get_gap_left)"; R="$(gap_right_for "$L")"
  cat "$TILE_DIR/globals.toml"
  sed -e "s/__XDR_GAP_LEFT__/$L/" -e "s/__XDR_GAP_RIGHT__/$R/" "$TILE_DIR/split.gaps.toml"
  cat "$TILE_DIR/modes.toml"
}

# --- Debug tracing ---------------------------------------------------------
# When TILE_TRACE names a file, `trace <label>` appends a full snapshot of the
# Tiles workspace (z-order + geometry + parent-container layout) after a step, so
# a whole transition can be replayed and inspected for flicker. Unset => zero
# overhead. Enable e.g.:  TILE_TRACE=/tmp/tile.log ./relayout.sh 255 38
FRAMES_SRC="$TILE_DIR/tools/frames.swift"
FRAMES_BIN="$TILE_DIR/tools/.frames-bin"
# ms-precision wall clock + epoch (BSD `date` has no %N, so use perl).
_ts()  { perl -MTime::HiRes=time -e 'my $t=time;my@l=localtime($t);printf"%02d:%02d:%02d.%03d",$l[2],$l[1],$l[0],($t-int($t))*1000' 2>/dev/null || date '+%H:%M:%S'; }
_now() { perl -MTime::HiRes=time -e 'printf"%.3f",time' 2>/dev/null || date +%s; }

# trace_begin <invocation>: log a header with the command that started this
# process and (re)mark the elapsed-time origin. Call once at the top of a script.
trace_begin() {
  [ -n "${TILE_TRACE:-}" ] || return 0
  : "${TILE_TRACE_T0:=$(_now)}"; export TILE_TRACE_T0
  printf '\n═══════════ %s │ CMD: %s │ pid=%s\n' "$(_ts)" "$*" "$$" >> "$TILE_TRACE"
}

# trace <label>: append a full workspace snapshot (z-order + geometry + parent
# layout) tagged with wall-clock time and Δ since trace_begin. Zero cost unless
# TILE_TRACE is set.
trace() {
  [ -n "${TILE_TRACE:-}" ] || return 0
  if [ ! -x "$FRAMES_BIN" ] || [ "$FRAMES_SRC" -nt "$FRAMES_BIN" ]; then
    swiftc -O "$FRAMES_SRC" -o "$FRAMES_BIN" 2>/dev/null
  fi
  local now el
  now="$(_now)"
  el="$(awk -v a="${TILE_TRACE_T0:-$now}" -v b="$now" 'BEGIN{printf"%+.3f",b-a}')"
  {
    echo "──── [$(_ts) Δ${el}s] $* ────  (focused=$(focused_window))"
    "$TILE_DIR/tools/snapshot.sh" 2>/dev/null
    echo
  } >> "$TILE_TRACE"
}
