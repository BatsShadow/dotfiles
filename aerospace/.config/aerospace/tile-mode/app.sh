#!/usr/bin/env bash
# Tile-mode app key handler. Two intents, selected by --stage:
#
#   Look (default) — pure attention; NEVER mutates the layout.
#     1. No matching window            -> launch the app (or open a window for
#        the role), or under --no-launch do nothing at all.
#     2. Already focused on a match     -> run --on-focus action (e.g. cycle tabs).
#     3. A match only on Aux (built-in) -> focus it there, in place.
#     4. Otherwise                      -> focus the nearest match. Focusing a
#        Rail window raises it to the accordion front (readable); focusing the
#        Stage window focuses the Stage. No promote, no relayout.
#
#   Stage (--stage) — arrangement; promote the nearest match onto the Stage
#     (pulled from Aux/anywhere first). Focus follows. This is the deliberate
#     "make this my primary surface" verb.
#
# Options:
#   --app-id <bundle-id>   (required)  match windows by app bundle id
#   --app-name <name>                  used only for launching
#   --on-focus <cmd>                   Look only: run when already focused on a match
#   --role <role>                      match only this role's remembered window
#                                      (window-roles.sh); with none, open one
#   --stage                            promote the match to the Stage instead of just focusing
#   --no-launch                        never start the app; with no match the key
#                                      is inert. For apps that should only ever be
#                                      opened by something else (Zoom, from a
#                                      meeting link).
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
source "$AERO_DIR/window-roles.sh"
trace_begin "app.sh $*"

APP_ID=""; APP_NAME=""; ON_FOCUS=""; STAGE=0; NO_LAUNCH=0; ROLE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-id) APP_ID="$2"; shift 2 ;;
    --app-name) APP_NAME="$2"; shift 2 ;;
    --on-focus) ON_FOCUS="$2"; shift 2 ;;
    --role) ROLE="$2"; shift 2 ;;
    --stage) STAGE=1; shift ;;
    --no-launch) NO_LAUNCH=1; shift ;;
    *) shift ;;
  esac
done

# Every window of this app: window-id<TAB>workspace.
app_windows() {
  aerospace list-windows --all --format '%{window-id}%{tab}%{app-bundle-id}%{tab}%{workspace}' 2>/dev/null \
  | awk -F'\t' -v bid="$APP_ID" '$2==bid { print $1 "\t" $3 }'
}

# A role names one window, so it is the only match. With none remembered or
# adoptable, open one: born in the Rail, the same as a launch below. Adoption
# looks on the role's workspace, which tile mode has emptied into Tiles, so a
# relaunched app gets a new window here rather than a restored one.
if [ -n "$ROLE" ]; then
  ROLE_WINDOW="$(role_find "$ROLE" "$APP_ID")"
  if [ -z "$ROLE_WINDOW" ]; then
    [ "$NO_LAUNCH" -eq 1 ] && exit 0
    park_focus_in_rail
    role_launch "$APP_ID" && ROLE_WINDOW="$(role_find "$ROLE" "$APP_ID")"
    [ -z "$ROLE_WINDOW" ] && { role_create "$ROLE" "$APP_ID" >/dev/null; exit 0; }
  fi
  MATCHES="$(printf '%s\t%s' "$ROLE_WINDOW" "$(window_workspace "$ROLE_WINDOW")")"
else
  MATCHES="$(app_windows)"
fi

# 1. Nothing running -> launch.
# Park focus in the Rail FIRST: the new window is born as a sibling of whatever
# is focused, so launching with the master focused would hang the newcomer off
# the root as a third column instead of the Rail (see park_focus_in_rail).
# Prevention, not repair — once born in the wrong container it takes tree surgery
# (alt-0) to fold back in.
if [ -z "$MATCHES" ]; then
  # --no-launch: no window to look at and we refuse to make one, so stop here
  # before park_focus_in_rail moves focus for a launch that will never happen.
  [ "$NO_LAUNCH" -eq 1 ] && exit 0
  park_focus_in_rail
  open -b "$APP_ID"
  exit 0
fi

FOCUSED="$(focused_window)"

# Nearest match by location: prefer the Stage/Rail, then Aux, then anywhere.
TILES_MATCH="$(awk -F'\t' -v ws="$PRIMARY_WS"   '$2==ws{print $1; exit}' <<< "$MATCHES")"
AUX_MATCH="$(awk   -F'\t' -v ws="$SECONDARY_WS" '$2==ws{print $1; exit}' <<< "$MATCHES")"
ANY_MATCH="$(head -n1 <<< "$MATCHES" | cut -f1)"

# --- Stage intent: promote the nearest match onto the Stage. Focus follows. ---
if [ "$STAGE" = 1 ]; then
  "$TILE_DIR/promote.sh" "${TILES_MATCH:-${AUX_MATCH:-$ANY_MATCH}}"
  exit 0
fi

# --- Look intent (pure attention). ---

# 2. Already focused on a match -> secondary action.
if [ -n "$ON_FOCUS" ]; then
  while IFS=$'\t' read -r wid _; do
    [ "$wid" = "$FOCUSED" ] && { eval "$ON_FOCUS"; exit 0; }
  done <<< "$MATCHES"
fi

# 3. Match only on Aux -> focus it there, in place.
if [ -z "$TILES_MATCH" ] && [ -n "$AUX_MATCH" ]; then
  aerospace workspace "$SECONDARY_WS"
  aerospace focus --window-id "$AUX_MATCH"
  exit 0
fi

# 4. Focus the nearest match on the XDR (Rail window rises to the accordion front).
TARGET="${TILES_MATCH:-$ANY_MATCH}"
aerospace focus --window-id "$TARGET"
# Keep the accordion-front hint coherent so promote's swap fast-path stays honest.
[ "$(parent_layout "$TARGET")" = "v_accordion" ] && set_secondary "$TARGET"
