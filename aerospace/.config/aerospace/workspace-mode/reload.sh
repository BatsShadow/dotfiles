#!/usr/bin/env bash
# Re-render the workspace-mode config from source and reload, then notify.
# A bare `aerospace reload-config` reloads the GENERATED aerospace.toml and
# ignores fresh edits to modes.toml / globals.toml. auto-config.aerospace.sh
# regenerates that artifact (globals + gaps + modes) from source and reloads;
# passing "W" re-applies the current workspace's saved layout (so the visible
# result is unchanged). AUTO_CONFIG_FORCE gets past the off-XDR exit and the
# skip for an unchanged config, so the reload happens whichever monitor is
# focused and even when the generated file came out the same.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

AUTO_CONFIG_FORCE=1 "$SCRIPT_DIR/auto-config.aerospace.sh" W >/dev/null 2>&1

osascript -e 'display notification "Config reloaded" with title "AeroSpace"' &
