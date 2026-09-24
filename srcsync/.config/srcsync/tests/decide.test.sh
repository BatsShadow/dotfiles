#!/usr/bin/env bash
# The apply rule as a table. Each row is one situation between two machines and
# the one answer that keeps work from being lost: take theirs only when this
# side has nothing they lack, and call it a conflict when both have moved.
#
# States are named by letter. S0 is where both started, A1 and B1 are each
# side's first change, A2 builds on B1.
#
#   ./decide.test.sh

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DECIDE=$(cd "$TESTS/.." && pwd -P)/lib/decide.jq

# State $1, with claude tree $2 when given. Off, the key is absent.
st() {
	printf '{"branch":"main","head":"h-%s","tree":"t-%s"%s}' "$1" "$1" "${2:+,\"claude\":\"c-$2\"}"
}
# An entry: state $1, based on state $2 ("-" for none), changed at $3, with
# claude trees $4 and $5 for the state and the base when given.
entry() {
	local base=null
	[ "$2" = - ] || base=$(st "$2" "${5:-}")
	jq -c --argjson b "$base" --arg at "$3" '. + {snapshot: "s", changed_at: $at, base: $b}' <<<"$(st "$1" "${4:-}")"
}

# mine now theirs removed_at ff_forward ff_back -> decision
row() { # want label mine now theirs [removed_at] [ff_forward] [ff_back]
	local got
	got=$(jq -cn --argjson mine "$3" --argjson now "$4" --argjson theirs "$5" \
		--argjson removed_at "${6:-null}" --argjson ff_forward "${7:-null}" --argjson ff_back "${8:-null}" \
		'{$mine, $now, $theirs, $removed_at, $ff_forward, $ff_back}' | jq -r -f "$DECIDE")
	assert_eq "$1" "$got" "$2"
}

printf 'the normal flow\n'
row same "both sides already match" \
	"$(entry S0 - 1)" "$(st S0)" "$(entry S0 - 1)"
row apply "they built on my latest, I have not touched it" \
	"$(entry S0 - 1)" "$(st S0)" "$(entry A1 S0 2)"
row apply "I only hold what I took from them, and they moved on" \
	"$(entry A1 A1 2)" "$(st A1)" "$(entry A2 - 3)"
row ahead "they have not moved since I took theirs" \
	"$(entry B1 A1 3)" "$(st B1)" "$(entry A1 - 2)"

printf 'divergence\n'
row conflict "both published changes from the same start" \
	"$(entry B1 S0 3)" "$(st B1)" "$(entry A1 S0 2)"
row conflict "they moved on, and I have unpublished work" \
	"$(entry S0 - 1)" "$(st B1)" "$(entry A1 S0 2)"
row ahead "unpublished work here, and they have not moved" \
	"$(entry A1 A1 2)" "$(st B1)" "$(entry A1 - 2)"

printf 'first contact\n'
row check-ff "neither side has taken anything from the other" \
	"$(entry S0 - 1)" "$(st S0)" "$(entry A1 - 2)"
row check-ff "this machine has never published" \
	null "$(st S0)" "$(entry A1 - 2)"
row apply "stale clean clone behind theirs" \
	null "$(st S0)" "$(entry A1 - 2)" null true false
row ahead "theirs is behind this clean clone" \
	null "$(st A1)" "$(entry S0 - 1)" null false true
row conflict "neither is an ancestor of the other" \
	null "$(st B1)" "$(entry A1 - 2)" null false false

printf 'absent worktrees\n'
row apply "a worktree this machine never had" \
	null null "$(entry A1 - 2)"
row ahead "removed here since publishing it" \
	"$(entry S0 - 1)" null "$(entry S0 - 1)"
row apply "removed here, but they moved on since" \
	"$(entry S0 - 1)" null "$(entry A1 S0 2)"
row ahead "removed here, and theirs is what I took from them" \
	"$(entry A1 A1 2)" null "$(entry A1 - 2)"
row ahead "removal published here after their last change" \
	null null "$(entry A1 - 2026-09-01T00:00:00Z)" '"2026-09-02T00:00:00Z"'
row apply "their change is newer than the removal here" \
	null null "$(entry A1 - 2026-09-03T00:00:00Z)" '"2026-09-02T00:00:00Z"'

printf 'claude transcripts\n'
row apply "same code, and they built a newer transcript on mine" \
	"$(entry S0 - 1 C0)" "$(st S0 C0)" "$(entry S0 S0 2 C1 C0)"
row conflict "my transcript moved here, and theirs moved too" \
	"$(entry S0 - 1 C0)" "$(st S0 C2)" "$(entry S0 S0 2 C1 C0)"

done_testing
