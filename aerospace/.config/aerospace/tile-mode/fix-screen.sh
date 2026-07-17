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
#
# Direction comes from SCREEN GEOMETRY, never from list order: `aerospace
# list-windows` sorts alphabetically by app name, so tree position cannot be read
# from it (see lib.sh "Geometry"). Each step re-measures, because every move
# changes the very positions the next decision depends on.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
trace_begin "fix-screen.sh"

[ "$(cat "$AERO_DIR/.current-mode" 2>/dev/null)" = "tile" ] || exit 0

MASTER="$(get_master)"

# Flat list of the primary workspace: "<window-id>\t<parent-layout>".
# ORDER IS ALPHABETICAL BY APP NAME — meaningful for membership only.
tree() {
  aerospace list-windows --workspace "$PRIMARY_WS" \
    --format '%{window-id}%{tab}%{window-parent-container-layout}' 2>/dev/null
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

# Nothing to fold INTO: with no accordion in the tree there is no rail yet (e.g.
# the master is alone with one newcomer). Building one needs the eject rebuild,
# which is alt-0's job, not this surgical pass. Leave the tree untouched.
if [ -z "$(rail_windows)" ]; then
  trace "no accordion in the tree — nothing to fold into (use alt-0)"
  exit 0
fi

# Fold each stray toward the rail, one measured step at a time. Moving toward a
# container enters it; moving toward a sibling window swaps (harmless) and the
# next step re-measures and continues, so a stray several columns out converges.
for stray in "${STRAYS[@]}"; do
  for _ in 1 2 3 4 5 6; do
    is_accordion "$(parent_layout "$stray")" && break

    RAIL_X="$(rail_xcenter)"
    SX="$(window_xcenter "$stray")"
    # Off-screen/unmeasurable: refuse to guess. A wrong guess repeated is what
    # rotates the whole tree; doing nothing leaves alt-0 as a clean recovery.
    [ -z "$RAIL_X" ] || [ -z "$SX" ] && { trace "stray $stray unmeasurable; skipping"; break; }

    if [ "$SX" -lt "$RAIL_X" ]; then
      aerospace move --window-id "$stray" right 2>/dev/null || break
    else
      aerospace move --window-id "$stray" left 2>/dev/null || break
    fi

    sleep 0.15                       # let the window server settle before re-measuring
    NEW_SX="$(window_xcenter "$stray")"
    # Wedged: the move reported success but the window did not actually go
    # anywhere. Stop rather than hammer the tree with more blind moves.
    [ "$NEW_SX" = "$SX" ] && { trace "stray $stray did not move; giving up"; break; }
  done
  trace "stray $stray -> $(parent_layout "$stray")"
done

# A stray column steals width from the master; restore the split. Focus is left
# wherever the user had it.
aerospace resize --window-id "$MASTER" width "$(get_width)" 2>/dev/null
trace "done"
