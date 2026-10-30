#!/usr/bin/env bash
# Workspace-mode gaps: render the config for a mode, install it only when it
# changed, and get a workspace's gaps in place before switching to it.
# Sourced by auto-config.aerospace.sh and dispatch.sh. Bash 3.2 safe.
#
# Gaps are per monitor, not per workspace, so a workspace is laid out with
# whatever config is loaded when it appears. Switching first and reloading
# after drew every switch twice: the new workspace at the old gaps, then
# ~0.3s later at its own. Writing the config first and sending reload-config
# and the switch as one `aerospace eval` drew it once, at its own gaps, with
# nothing visible happening to the workspace being left. Seen by eye
# 2026-10-30, Slack (mode 1) to Zoom and Terminal (mode 2), and to Terminal in
# mode 1 with its 30px padding adjustment.
#
# Only a saved mode can be applied ahead. A hidden workspace's windows sit in
# a screen corner, so its columns can't be read until it shows. Every
# auto-config run saves the mode it applied, so a workspace lacks one only
# until its first visit.

GAPS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GAPS_CONFIG="${GAPS_CONFIG:-$GAPS_DIR/../aerospace.toml}"
GAPS_MODES="${GAPS_MODES:-$GAPS_DIR/.workspace-window-modes.toml}"

# gaps_render <mode> <tiled-window-count>: the whole config for a mode. The
# one-window file's 850 right gap shrinks 15px per window past the first,
# room for accordion padding.
gaps_render() {
  local file=n-windows.gaps.toml adj=$((15 * ($2 - 1)))
  case "$1" in
    1) file=one-window.gaps.toml ;;
    2) file=two-windows.gaps.toml ;;
  esac
  cat "$GAPS_DIR/globals.toml"
  perl -pe "s/850/$((850 - adj))/" "$GAPS_DIR/$file"
  cat "$GAPS_DIR/modes.toml"
}

# gaps_install <mode> <tiled-window-count>: write the config if it differs
# from what is loaded. Returns 0 when it changed and needs a reload.
gaps_install() {
  local tmp
  tmp=$(mktemp -t aerospace-config) || return 1
  gaps_render "$1" "$2" >"$tmp"
  if cmp -s "$tmp" "$GAPS_CONFIG"; then
    rm -f "$tmp"
    return 1
  fi
  # Copied, not moved, so AeroSpace never reads a half-written file and the
  # config keeps its own permissions.
  cp "$tmp" "$GAPS_CONFIG"
  rm -f "$tmp"
  return 0
}

gaps_saved_mode() { # workspace
  awk -v ws="$1" '$1 == ws && $2 == "=" { print $3; exit }' "$GAPS_MODES" 2>/dev/null
}

# gaps_prepare <workspace>: install the gaps <workspace> needs, before the
# switch. Sets GAPS_RELOAD=1 when the config changed. Returns
#   0  ready: switch with `eval 'reload-config; workspace X'` if GAPS_RELOAD
#   1  no saved mode, or no XDR among two or more monitors: switch, then run
#      auto-config as before
#   2  on a monitor workspace mode leaves alone: switch, nothing to re-gap
gaps_prepare() {
  local ws="$1" all mode count
  GAPS_RELOAD=0
  all=$(aerospace list-workspaces --all --format '%{workspace}|%{monitor-name}' 2>/dev/null)
  if printf '%s\n' "$all" | awk -F'|' 'tolower($2) ~ /xdr/ { f = 1 } END { exit !f }'; then
    printf '%s\n' "$all" | awk -F'|' -v ws="$ws" '$1 == ws && tolower($2) ~ /xdr/ { f = 1 } END { exit !f }' ||
      return 2
  elif [ "$(aerospace list-monitors --count 2>/dev/null)" != 1 ]; then
    return 1
  fi
  mode=$(gaps_saved_mode "$ws")
  [ -n "$mode" ] || return 1
  count=$(aerospace list-windows --workspace "$ws" --format '%{window-parent-container-layout}' 2>/dev/null |
    grep -cv '^floating$')
  [ "${count:-0}" -gt 0 ] || count=1
  gaps_install "$mode" "$count" && GAPS_RELOAD=1
  return 0
}
