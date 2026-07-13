#!/usr/bin/env bash
# alt-V "fix screen": surgically fold any stray root-level window back into the
# rail, WITHOUT rebuilding the whole layout.
#
# The canonical tile-mode tree is:
#     h_tiles[ master | <accordion>[ …rail… ] ]                 (dual monitor)
#     h_accordion[ …everything… ]                               (single monitor)
# A "stray" is a window sitting as a direct child of the root tiled container
# (like the master) instead of inside the accordion — e.g. a window returning
# from macOS-native fullscreen, which AeroSpace re-tiles at the tree root. This
# moves ONLY those strays into the accordion and leaves everything else — focus,
# the rail's front window, the master — untouched. No flatten, no relayout, no
# mass refocus (that heavier rebuild is alt-0 / relayout.sh).
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
trace_begin "fix-screen.sh"

[ "$(cat "$AERO_DIR/.current-mode" 2>/dev/null)" = "tile" ] || exit 0

MASTER="$(get_master)"

is_accordion() { case "$1" in *accordion) return 0 ;; *) return 1 ;; esac; }

# Flat DFS tree order of the primary workspace: "<window-id>\t<parent-layout>".
tree() {
  aerospace list-windows --workspace "$PRIMARY_WS" \
    --format '%{window-id}%{tab}%{window-parent-container-layout}' 2>/dev/null
}

# Echo "<stray-index> <first-accordion-index>" for a window id (-1 when absent).
# Index is position in DFS order, which tells us whether the stray is to the
# left of the rail (move it right to enter) or to the right (move it left).
locate() {
  local target="$1" i=0 sidx=-1 facc=-1 wid layout
  while IFS=$'\t' read -r wid layout; do
    [ "$wid" = "$target" ] && sidx=$i
    if is_accordion "$layout" && [ "$facc" -lt 0 ]; then facc=$i; fi
    i=$((i + 1))
  done < <(tree)
  echo "$sidx $facc"
}

# Collect the strays up front (their ids stay valid as the tree changes).
STRAYS=()
while IFS=$'\t' read -r wid layout; do
  [ -z "$wid" ] && continue
  [ "$wid" = "$MASTER" ] && continue
  is_accordion "$layout" || STRAYS+=("$wid")
done < <(tree)

if [ "${#STRAYS[@]}" -eq 0 ]; then
  trace "no strays; nothing to fix"
  exit 0
fi

# Fold each stray toward the rail one step at a time until it is inside the
# accordion. Moving toward a container enters it; moving toward a sibling window
# just swaps (harmless) and the next step continues in the same direction, so a
# stray several columns away still converges. Capped so a degenerate tree (no
# accordion to enter) can't spin.
for stray in "${STRAYS[@]}"; do
  for _ in 1 2 3 4 5 6 7 8; do
    is_accordion "$(parent_layout "$stray")" && break
    read -r sidx facc < <(locate "$stray")
    [ "$facc" -lt 0 ] && break            # no accordion in the tree — can't fold
    if [ "$sidx" -lt "$facc" ]; then
      aerospace move --window-id "$stray" right 2>/dev/null || break
    else
      aerospace move --window-id "$stray" left 2>/dev/null || break
    fi
  done
  trace "stray $stray -> $(parent_layout "$stray")"
done

# A stray column steals width from the master; restore the split. Focus is left
# wherever the user had it.
aerospace resize --window-id "$MASTER" width "$(get_width)" 2>/dev/null
trace "done"
