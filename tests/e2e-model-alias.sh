#!/usr/bin/env bash
# tests/e2e-model-alias.sh -- does --model <family> follow its ANTHROPIC_DEFAULT_<FAMILY>_MODEL export?
#
# Why this matters: the claude-* aliases in bash/shared.bash pass a family name (opus, fable, opusplan).
# A model bump edits one export and no alias only if Claude Code resolves the family through that export.
# tests/test-shared-bash-aliases.sh checks the file. This suite checks what a live session does with it.
#
# Method: each case starts `claude -p` in an empty temp directory with project settings only, so no user
# hooks and no memory load. The export under test names a model that differs from the family default.
# The suite reads the served model from `modelUsage` in the JSON result. It never trusts the model's own words.
#
# Usage (spends a few cents):
#   E2E=1 bash tests/e2e-model-alias.sh
# Env:
#   E2E_MODEL_A, E2E_MODEL_B  two cheap, valid model ids (defaults: claude-sonnet-5-5, claude-haiku-4-5)

set -u

[ "${E2E:-}" = 1 ] || {
	echo "skip: set E2E=1 to run (spends tokens)"
	exit 0
}
for tool in claude jq; do
	command -v "$tool" >/dev/null 2>&1 || {
		echo "skip: $tool is required"
		exit 0
	}
done

A="${E2E_MODEL_A:-claude-sonnet-5-5}"
B="${E2E_MODEL_B:-claude-haiku-4-5}"
PASS=0
FAIL=0

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/e2e-model-alias.XXXXXX")"
trap 'rm -rf "$TMPD"' EXIT

assert_eq() {
	local name="$1" expected="$2" actual="$3"
	if [ "$expected" = "$actual" ]; then
		printf '  PASS  %s\n' "$name"
		PASS=$((PASS + 1))
	else
		printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$name" "$expected" "$actual"
		FAIL=$((FAIL + 1))
	fi
}

# served <VAR=value>... claude <flags>: run the command, print the served model, or ERROR when the call fails.
served() {
	(cd "$TMPD" && env "$@" -p "reply with the single word ok" --setting-sources project \
		--output-format json --no-session-persistence --max-budget-usd 0.5 </dev/null 2>/dev/null) \
		| jq -r 'if .is_error then "ERROR" else (.modelUsage | keys | join(",")) end' 2>/dev/null
}

echo "--- live resolution (served model read from modelUsage)"
assert_eq "1 opus follows its export" "$A" "$(served ANTHROPIC_DEFAULT_OPUS_MODEL="$A" claude --model opus)"
assert_eq "2 fable follows its export" "$A" "$(served ANTHROPIC_DEFAULT_FABLE_MODEL="$A" claude --model fable)"
assert_eq "3 opusplan outside plan mode uses the sonnet export" "$B" \
	"$(served ANTHROPIC_DEFAULT_OPUS_MODEL="$A" ANTHROPIC_DEFAULT_SONNET_MODEL="$B" claude --model opusplan --permission-mode default)"
assert_eq "4 opusplan in plan mode uses the opus export" "$A" \
	"$(served ANTHROPIC_DEFAULT_OPUS_MODEL="$A" ANTHROPIC_DEFAULT_SONNET_MODEL="$B" claude --model opusplan --permission-mode plan)"

echo "--- fail-to-fail: a bare model name is rejected (the reason the aliases use the family name)"
assert_eq "5 claude-opus is rejected" "ERROR" "$(served ANTHROPIC_DEFAULT_OPUS_MODEL="$A" claude --model claude-opus)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
