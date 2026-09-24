# shellcheck shell=bash
# srcsync conflicts and sync age.
#
# Reads srcsync's own state files directly rather than sourcing its libs: this
# runs every second, and sourcing lib/common.sh and friends on that interval
# is the cost the claude_sessions segment above already ruled out for the same
# reason. Silent whenever `auto off` (the default), since a segment reporting
# on a feature nobody turned on is noise.
#
# State read here, as srcsync's lib/common.sh writes it:
#   $SRCSYNC_STATE/conflicts.json  JSON array from `jq -s .`, one object per
#                                  conflict; length is the count.
#   $SRCSYNC_STATE/last-success    one `date -u +%Y-%m-%dT%H:%M:%SZ` line,
#                                  written by publish.sh on a clean run.

# The auto rule from lib/common.sh's load_config: last line wins, off if absent.
config_auto_state() { # config path
	local config="$1" kw a b auto=off
	[ -f "$config" ] || { printf '%s' "$auto"; return 0; }
	while read -r kw a b; do
		case "$kw" in
		'' | \#*) ;;
		auto) auto="$a" ;;
		esac
	done <"$config"
	printf '%s' "$auto"
}

run_segment() {
	local state="${SRCSYNC_STATE:-$HOME/.local/state/srcsync}"
	local config="${SRCSYNC_CONFIG:-$HOME/.config/srcsync/config}"

	[ "$(config_auto_state "$config")" = on ] || return 0

	local conflicts="$state/conflicts.json" n=0
	if [ -f "$conflicts" ]; then
		n=$(jq 'length' "$conflicts" 2>/dev/null)
		case "$n" in '' | *[!0-9]*) n=0 ;; esac
	fi
	if [ "$n" -gt 0 ]; then
		printf '⇄ !%s' "$n"
		return 0
	fi

	local ts
	ts=$(cat "$state/last-success" 2>/dev/null)
	if [ -z "$ts" ]; then
		printf '⇄ never'
		return 0
	fi

	# -j -f parses without needing GNU date's -d; this is macOS only, so no
	# GNU fallback branch.
	local now_epoch ts_epoch
	now_epoch=$(date -u +%s)
	ts_epoch=$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$ts" +%s 2>/dev/null)
	if [ -z "$ts_epoch" ]; then
		printf '⇄ never'
		return 0
	fi

	local age=$((now_epoch - ts_epoch))
	[ "$age" -lt 900 ] && return 0

	local mins=$((age / 60))
	if [ "$mins" -lt 60 ]; then
		printf '⇄ %sm' "$mins"
	else
		printf '⇄ %sh' $((mins / 60))
	fi
	return 0
}
