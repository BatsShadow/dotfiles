#!/usr/bin/env bash
# Swap the browser keys between Arc (main) and Crest (crest-browser).
# Bound to `b` in service mode (alt-backslash, then b).
#
# The two browsers live on two branches, and the stowed checkout is the live
# config, so switching browsers is a branch switch plus a re-render of
# aerospace.toml for the current mode. Each branch carries this script, so
# the key works from either side.
#
# A dirty tree refuses rather than carrying edits across, since `git switch`
# would either fail or move half-done work onto the other browser.
#
# The body is in braces: bash reads a script as it runs, and the switch can
# rewrite this file underneath it.

{
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  notify() { osascript -e "display notification \"$1\" with title \"AeroSpace\"" & }

  BRANCH=$(git -C "$SCRIPT_DIR" branch --show-current)
  case "$BRANCH" in
    main) TARGET=crest-browser NAME=Crest ;;
    crest-browser) TARGET=main NAME=Arc ;;
    *) notify "Dotfiles are on $BRANCH, not a browser branch"; exit 1 ;;
  esac

  if [ -n "$(git -C "$SCRIPT_DIR" status --porcelain)" ]; then
    notify "Dotfiles have uncommitted changes, staying on $BRANCH"
    exit 1
  fi

  if ! git -C "$SCRIPT_DIR" switch -q "$TARGET"; then
    notify "Could not switch dotfiles to $TARGET"
    exit 1
  fi

  # toggle-mode.sh reads a missing mode file as tile, so this does too.
  if [ "$(cat "$SCRIPT_DIR/.current-mode" 2>/dev/null || echo tile)" = tile ]; then
    "$SCRIPT_DIR/tile-mode/reload.sh" >/dev/null 2>&1
  else
    "$SCRIPT_DIR/workspace-mode/auto-config.aerospace.sh" W >/dev/null 2>&1
  fi
  notify "Browser keys now drive $NAME"
  exit 0
}
