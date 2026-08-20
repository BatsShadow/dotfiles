#!/usr/bin/env bash
# Given an app-bundle-id and window-title, return the workspace name.
# Mirrors the on-window-detected rules from workspace-mode/modes.toml.
# Usage: resolve-workspace.sh <app-bundle-id> <window-title>
# Returns: workspace name on stdout

APP_ID="$1"
TITLE="$2"

case "$APP_ID" in
  com.github.wez.wezterm)
    echo "Terminal"
    ;;
  com.apple.iCal)
    echo "Calendar"
    ;;
  com.hnc.Discord)
    echo "Discord"
    ;;
  company.thebrowser.Browser)
    # Arc — order matters: specific title matches before generic
    if echo "$TITLE" | grep -qi "Gmail"; then
      echo "Email"
    elif echo "$TITLE" | grep -qi "Messages for web"; then
      echo "Email"
    elif echo "$TITLE" | grep -qi "YouTube"; then
      echo "YouTube"
    else
      echo "Browser"
    fi
    ;;
  com.apple.Safari)
    echo "Safari"
    ;;
  com.tinyspeck.slackmacgap)
    echo "Slack"
    ;;
  md.obsidian)
    echo "Email"
    ;;
  us.zoom.xos)
    echo "Zoom"
    ;;
  *)
    echo "Browser"
    ;;
esac
