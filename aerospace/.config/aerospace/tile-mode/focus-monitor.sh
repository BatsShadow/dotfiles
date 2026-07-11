#!/usr/bin/env bash
# Cross-monitor focus movement (not app-based).
#   alt-A -> focus the built-in (far-left / secondary) monitor's window
#   alt-T -> focus back to the primary monitor (the master)
#
# Usage: focus-monitor.sh secondary|primary
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

case "${1:-}" in
  secondary|built-in|a)
    read_lines SEC < <(secondary_windows)
    if [ -n "${SEC[0]:-}" ]; then
      aerospace workspace "$SECONDARY_WS"
      aerospace focus --window-id "${SEC[0]}" 2>/dev/null
    fi
    ;;
  primary|master|t)
    aerospace workspace "$PRIMARY_WS"
    M="$(get_master)"
    if [ -n "$M" ] && window_exists "$M"; then
      aerospace focus --window-id "$M" 2>/dev/null
    fi
    ;;
esac
