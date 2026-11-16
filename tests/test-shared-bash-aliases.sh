#!/usr/bin/env bash
# tests/test-shared-bash-aliases.sh -- the claude-* aliases in bash/shared.bash name a valid model family.
#
# Why this matters: an alias passes --model <family> (opus, fable, opusplan). Claude Code resolves the family
# through ANTHROPIC_DEFAULT_<FAMILY>_MODEL, so a model bump edits one export and no alias. Two faults break
# that design without a message: a bare name such as claude-opus (Claude Code rejects it), and an empty
# export (the family loses its pin, and machines no longer agree on the model).
# An alias also beats the exported default only because --model outranks ANTHROPIC_MODEL (opusplan), so each
# alias must carry the flag. Every claude-* alias needs a row below: a new alias without a row fails.
# tests/e2e-model-alias.sh checks the live resolution. This suite never calls the API.
#
# shared.bash is sourced by login shells on a fresh Mac (bash 3.2) and on a configured Mac (Homebrew
# bash), so every check runs under /bin/bash and under the bash on PATH.
#
# Method: source shared.bash in a throwaway HOME, print the alias table and the model exports, and compare
# each alias with its row. Fail-to-fail cases break a copy of shared.bash and expect the checks to report it.
#
# Usage: bash tests/test-shared-bash-aliases.sh

set -u

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHARED_BASH="$REPO_DIR/bash/shared.bash"

PASS=0
FAIL=0

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

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/test-shared-bash-aliases.XXXXXX")"
trap 'rm -rf "$TMPD"' EXIT
mkdir -p "$TMPD/home"

# Each row: alias | --model value | effort | permission mode. An empty effort means the exported level.
ROWS=(
	"claude-fast|opusplan||bypassPermissions"
	"claude-turbo|opusplan|xhigh|bypassPermissions"
	"claude-fable-fast|fable|medium|bypassPermissions"
	"claude-fable-turbo|fable|high|bypassPermissions"
	"claude-fable-hyper|fable|xhigh|bypassPermissions"
	"claude-fable-max|fable|max|bypassPermissions"
	"claude-opus|opus|high|bypassPermissions"
	"claude-opus-turbo|opus|xhigh|bypassPermissions"
	"claude-opus-max|opus|max|bypassPermissions"
)

# dump <bash> <shared.bash>: source the file in a throwaway HOME and print the alias table and the exports.
dump() {
	# shellcheck disable=SC2016 # the given bash expands these variables, not this shell
	env -i HOME="$TMPD/home" PATH="$PATH" "$1" -c '
		shopt -s expand_aliases
		. "$1" >/dev/null 2>&1
		alias
		printf "EXPORT ANTHROPIC_MODEL=%s\n" "$ANTHROPIC_MODEL"
		printf "EXPORT ANTHROPIC_DEFAULT_FABLE_MODEL=%s\n" "$ANTHROPIC_DEFAULT_FABLE_MODEL"
		printf "EXPORT ANTHROPIC_DEFAULT_OPUS_MODEL=%s\n" "$ANTHROPIC_DEFAULT_OPUS_MODEL"
		printf "EXPORT ANTHROPIC_DEFAULT_SONNET_MODEL=%s\n" "$ANTHROPIC_DEFAULT_SONNET_MODEL"
	' _ "$2"
}

# check_rows <bash> <shared.bash>: print one line for each fault. No output means no fault.
check_rows() {
	local out row name model effort perm def got eff known fam
	out="$(dump "$1" "$2")"
	known=" "
	for row in "${ROWS[@]}"; do
		IFS='|' read -r name model effort perm <<EOF
$row
EOF
		known="$known$name "
		def="$(printf '%s\n' "$out" | sed -n "s/^alias $name='\(.*\)'\$/\1/p")"
		if [ -z "$def" ]; then
			echo "$name: not defined"
			continue
		fi
		got="$(printf '%s\n' "$def" | sed -n 's/.*--model \([^ ]*\).*/\1/p')"
		[ "$got" = "$model" ] || echo "$name: model '$got', expected '$model'"
		eff="$(printf '%s\n' "$def" | sed -n 's/^CLAUDE_CODE_EFFORT_LEVEL=\([^ ]*\) .*/\1/p')"
		[ "$eff" = "$effort" ] || echo "$name: effort '$eff', expected '$effort'"
		case "$def" in
			*"--permission-mode $perm"*) ;;
			*) echo "$name: the permission mode is not $perm" ;;
		esac
	done
	# Every claude-* alias in the file needs a row.
	for name in $(printf '%s\n' "$out" | sed -n "s/^alias \(claude-[^=]*\)=.*/\1/p"); do
		case "$known" in
			*" $name "*) ;;
			*) echo "$name: defined but has no row in this test" ;;
		esac
	done
	# Every family that an alias uses, directly or through opusplan (opus and sonnet), needs a pinned model id.
	for fam in ANTHROPIC_DEFAULT_FABLE_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL; do
		[ -n "$(printf '%s\n' "$out" | sed -n "s/^EXPORT $fam=//p")" ] || echo "$fam: empty"
	done
}

for SH in /bin/bash "$(command -v bash)"; do
	# shellcheck disable=SC2016 # the given bash expands $BASH_VERSION, not this shell
	VER="$("$SH" -c 'printf %s "$BASH_VERSION"')"
	echo "--- aliases under $SH ($VER)"
	assert_eq "1.1 every claude-* alias matches its row" "" "$(check_rows "$SH" "$SHARED_BASH")"
	assert_eq "1.2 the default model stays opusplan" "opusplan" "$(dump "$SH" "$SHARED_BASH" | sed -n 's/^EXPORT ANTHROPIC_MODEL=//p')"
	# An interactive cp or mv alias prompts. A non-interactive shell answers "n" and skips the copy without an error.
	assert_eq "1.3 cp and mv are not aliased" "" "$(dump "$SH" "$SHARED_BASH" | grep -E '^alias (cp|mv)=')"
done

echo "--- fail-to-fail: broken copies of shared.bash are reported"
# 2.1: a bare model name, which Claude Code rejects.
sed "/^alias claude-opus-turbo=/s/--model opus/--model claude-opus/" "$SHARED_BASH" >"$TMPD/bare-name.bash"
assert_eq "2.1 a bare model name is reported" "claude-opus-turbo: model 'claude-opus', expected 'opus'" \
	"$(check_rows "$(command -v bash)" "$TMPD/bare-name.bash")"
# 2.2: an emptied export leaves the family unpinned.
sed 's/^export ANTHROPIC_DEFAULT_OPUS_MODEL=.*/export ANTHROPIC_DEFAULT_OPUS_MODEL=""/' "$SHARED_BASH" >"$TMPD/empty-export.bash"
assert_eq "2.2 an empty family export is reported" "ANTHROPIC_DEFAULT_OPUS_MODEL: empty" \
	"$(check_rows "$(command -v bash)" "$TMPD/empty-export.bash")"
# 2.3: an alias that nobody listed.
{
	cat "$SHARED_BASH"
	printf "alias claude-extra='claude --model opusplan --permission-mode bypassPermissions'\n"
} >"$TMPD/extra-alias.bash"
assert_eq "2.3 an alias without a row is reported" "claude-extra: defined but has no row in this test" \
	"$(check_rows "$(command -v bash)" "$TMPD/extra-alias.bash")"
# 2.4: an alias without the --model flag would not beat the exported ANTHROPIC_MODEL.
sed "/^alias claude-opus=/s/ --model opus//" "$SHARED_BASH" >"$TMPD/no-flag.bash"
assert_eq "2.4 an alias without --model is reported" "claude-opus: model '', expected 'opus'" \
	"$(check_rows "$(command -v bash)" "$TMPD/no-flag.bash")"
# 2.5: a cp alias that prompts.
{
	cat "$SHARED_BASH"
	printf "alias cp='cp -iv'\n"
} >"$TMPD/cp-alias.bash"
assert_eq "2.5 a cp alias is reported" "alias cp='cp -iv'" \
	"$(dump "$(command -v bash)" "$TMPD/cp-alias.bash" | grep -E '^alias (cp|mv)=')"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
