#!/usr/bin/env bash
# Read-only snapshot of the Tiles workspace for tracing/debugging: joins macOS
# z-order + window geometry (via the compiled frames tool) with AeroSpace's
# %{window-parent-container-layout}, into one annotated view. Has NO side effects
# (no focus changes), so it is safe to call between layout commands.
#
# Output columns: [*]=focused  z=stacking(0=front)  win  parent-layout  role  frame  app/title
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRAMES_BIN="$DIR/.frames-bin"

FOCUSED="$(aerospace list-windows --focused --format '%{window-id}' 2>/dev/null)"
AERO="$(aerospace list-windows --workspace Tiles \
        --format '%{window-id}	%{app-name}	%{window-parent-container-layout}	%{window-title}' 2>/dev/null)"

seen_col=0
"$FRAMES_BIN" 2>/dev/null | while IFS=$'\t' read -r z id x y w h; do
  row="$(awk -F'\t' -v i="$id" '$1==i{print;exit}' <<< "$AERO")"
  [ -z "$row" ] && continue                       # not a Tiles window (other monitor/app)
  app="$(cut -f2 <<< "$row")"; pl="$(cut -f3 <<< "$row")"; title="$(cut -f4 <<< "$row")"
  role="-"
  case "$pl" in
    h_tiles|h_tiles_*)  role="MASTER" ;;
    v_accordion|h_accordion)
        if [ "$seen_col" -eq 0 ]; then role="COL-FRONT"; seen_col=1; else role="col-peek"; fi ;;
    floating) role="float" ;;
  esac
  foc=" "; [ "$id" = "$FOCUSED" ] && foc="*"
  printf '%s z%-2s win#%-5s %-12s %-9s %5s,%-4s %5sx%-4s  %s | %.30s\n' \
    "$foc" "$z" "$id" "$pl" "$role" "$x" "$y" "$w" "$h" "$app" "$title"
done