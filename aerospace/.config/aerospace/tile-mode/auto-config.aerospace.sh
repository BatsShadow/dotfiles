#!/usr/bin/env bash
# Activate tile mode: generate the tile-mode aerospace.toml (globals + gaps +
# bindings), reload, then gather windows and lay them out via enter.sh.
# Works on one monitor (accordion) or two (master + weighted stack).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

cd "$SCRIPT_DIR" || exit 1

# Write to a temp file first, then move it in, so aerospace never reads a
# partially-written config. render_config concatenates globals + gaps + modes
# and substitutes the current XDR gap values (alt-W/alt-F state).
TEMP_CONFIG=$(mktemp -t aerospace-config)
render_config >"${TEMP_CONFIG}"
cp "$TEMP_CONFIG" ../aerospace.toml

aerospace reload-config
"$SCRIPT_DIR/enter.sh"

# Persist current mode
echo "tile" > "$SCRIPT_DIR/../.current-mode"
