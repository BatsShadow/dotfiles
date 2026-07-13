#!/usr/bin/env bash
# Tile-mode app key handler. Two intents, selected by --stage:
#
#   Look (default) — pure attention; NEVER mutates the layout.
#     1. No matching window            -> launch the app (or open the URL).
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
#   --find-title <substr>              additionally require this (case-insensitive) in the title
#   --exclude <regex>                  exclude windows whose title matches this (case-insensitive)
#   --on-focus <cmd>                   Look only: run when already focused on a match
#   --url <url>                        open this Arc URL instead of `open -b` when launching
#   --find-url <regex>                 additionally require the active tab URL to match (Arc)
#   --exclude-url <regex>              exclude windows whose active tab URL matches (Arc)
#   --stage                            promote the match to the Stage instead of just focusing
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
trace_begin "app.sh $*"

APP_ID=""; APP_NAME=""; FIND_TITLE=""; EXCLUDE=""; ON_FOCUS=""; URL=""; STAGE=0
FIND_URL=""; EXCLUDE_URL=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-id) APP_ID="$2"; shift 2 ;;
    --app-name) APP_NAME="$2"; shift 2 ;;
    --find-title) FIND_TITLE="$2"; shift 2 ;;
    --exclude) EXCLUDE="$2"; shift 2 ;;
    --on-focus) ON_FOCUS="$2"; shift 2 ;;
    --url) URL="$2"; shift 2 ;;
    --find-url) FIND_URL="$2"; shift 2 ;;
    --exclude-url) EXCLUDE_URL="$2"; shift 2 ;;
    --stage) STAGE=1; shift ;;
    *) shift ;;
  esac
done

# Candidate windows for this app: window-id<TAB>title<TAB>workspace (tree order).
app_windows() {
  aerospace list-windows --all --json \
    --format '%{window-id} %{app-bundle-id} %{window-title} %{workspace}' 2>/dev/null \
  | jq -r --arg bid "$APP_ID" '.[]
      | select(.["app-bundle-id"] == $bid)
      | "\(.["window-id"])\t\(.["window-title"])\t\(.workspace)"'
}

# Surviving windows -> "window-id<TAB>workspace" after title AND url filters.
# URL filters (Arc) classify a window by its active tab URL, since titles follow
# the page/video name and are unreliable. If Arc can't be queried (empty map),
# the url filters are skipped so matching degrades to title-only.
matches() {
  local urlmap="" id title ws url
  if [ -n "$FIND_URL" ] || [ -n "$EXCLUDE_URL" ]; then
    urlmap="$("$AERO_DIR/arc-window-urls.sh" 2>/dev/null)"
  fi
  while IFS=$'\t' read -r id title ws; do
    [ -z "$id" ] && continue
    if [ -n "$FIND_TITLE" ] && ! grep -qiE "$FIND_TITLE" <<< "$title"; then continue; fi
    if [ -n "$EXCLUDE" ]    &&   grep -qiE "$EXCLUDE"    <<< "$title"; then continue; fi
    if [ -n "$urlmap" ] && { [ -n "$FIND_URL" ] || [ -n "$EXCLUDE_URL" ]; }; then
      url="$(awk -F'\t' -v t="$title" '$1==t{print $2; exit}' <<< "$urlmap")"
      if [ -n "$FIND_URL" ]    && ! grep -qiE "$FIND_URL"    <<< "$url"; then continue; fi
      if [ -n "$EXCLUDE_URL" ] &&   grep -qiE "$EXCLUDE_URL" <<< "$url"; then continue; fi
    fi
    printf '%s\t%s\n' "$id" "$ws"
  done < <(app_windows)
}

MATCHES="$(matches)"

# 1. Nothing running -> launch.
if [ -z "$MATCHES" ]; then
  if [ -n "$URL" ]; then
    "$AERO_DIR/open-arc-url.sh" "$URL"
  else
    open -b "$APP_ID"
  fi
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
