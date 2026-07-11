#!/usr/bin/env bash
# Tile-mode app key handler.
#
#   1. No matching window        -> launch the app (or open the URL).
#   2. Already focused on a match -> run --on-focus action (e.g. cycle Arc tabs).
#   3. A match on the secondary monitor -> focus it there, in place (do NOT pull it back).
#   4. Otherwise                 -> promote a match to master.
#
# Options:
#   --app-id <bundle-id>   (required)  match windows by app bundle id
#   --app-name <name>                  used only for launching
#   --find-title <substr>              additionally require this (case-insensitive) in the title
#   --exclude <regex>                  exclude windows whose title matches this (case-insensitive)
#   --on-focus <cmd>                   run when already focused on a match
#   --url <url>                        open this Arc URL instead of `open -b` when launching
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

APP_ID=""; APP_NAME=""; FIND_TITLE=""; EXCLUDE=""; ON_FOCUS=""; URL=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-id) APP_ID="$2"; shift 2 ;;
    --app-name) APP_NAME="$2"; shift 2 ;;
    --find-title) FIND_TITLE="$2"; shift 2 ;;
    --exclude) EXCLUDE="$2"; shift 2 ;;
    --on-focus) ON_FOCUS="$2"; shift 2 ;;
    --url) URL="$2"; shift 2 ;;
    *) shift ;;
  esac
done

# Matching windows -> "window-id<TAB>workspace" lines.
matches() {
  aerospace list-windows --all --json \
    --format '%{window-id} %{app-bundle-id} %{window-title} %{workspace}' 2>/dev/null \
  | jq -r --arg bid "$APP_ID" --arg inc "$FIND_TITLE" --arg exc "$EXCLUDE" '
      .[]
      | select(.["app-bundle-id"] == $bid)
      | select($inc == "" or (.["window-title"] | test($inc; "i")))
      | select($exc == "" or ((.["window-title"] | test($exc; "i")) | not))
      | "\(.["window-id"])\t\(.workspace)"
    '
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

# 2. Already focused on a match -> secondary action.
if [ -n "$ON_FOCUS" ]; then
  while IFS=$'\t' read -r wid _; do
    [ "$wid" = "$FOCUSED" ] && { eval "$ON_FOCUS"; exit 0; }
  done <<< "$MATCHES"
fi

# 3. Match on the secondary monitor -> focus it in place.
SEC_MATCH="$(awk -F'\t' -v ws="$SECONDARY_WS" '$2==ws{print $1; exit}' <<< "$MATCHES")"
if [ -n "$SEC_MATCH" ]; then
  aerospace workspace "$SECONDARY_WS"
  aerospace focus --window-id "$SEC_MATCH"
  exit 0
fi

# 4. Promote a match to master (prefer one already on Tiles).
PROMOTE="$(awk -F'\t' -v ws="$PRIMARY_WS" '$2==ws{print $1; exit}' <<< "$MATCHES")"
[ -z "$PROMOTE" ] && PROMOTE="$(head -n1 <<< "$MATCHES" | cut -f1)"
"$TILE_DIR/promote.sh" "$PROMOTE"
