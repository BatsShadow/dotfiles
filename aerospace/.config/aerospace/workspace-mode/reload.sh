#!/usr/bin/env bash
# Re-render the workspace-mode config from source and reload, then notify.
# A bare `aerospace reload-config` reloads the GENERATED aerospace.toml and
# ignores fresh edits to modes.toml / globals.toml. auto-config.aerospace.sh
# regenerates that artifact (globals + gaps + modes) from source and reloads;
# passing "W" re-applies the current workspace's saved layout (so the visible
# result is unchanged) and, being a non-empty arg, bypasses the off-XDR guard so
# the reload works regardless of which monitor is focused.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$SCRIPT_DIR/auto-config.aerospace.sh" W >/dev/null 2>&1

osascript -e 'display notification "Config reloaded" with title "AeroSpace"' &
