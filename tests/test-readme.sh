#!/usr/bin/env bash
# tests/test-readme.sh -- README.md stays short, plain, and public.
#
# Why: the README grew to 530 lines and 6,600 words, and it read as one person's notes. Anyone who finds
# the repo needs the answer to four questions: what it is, how to install it, how to check it, and how
# to change it. This suite holds the README to that job. The limits are:
#   - 150 lines and 1,200 words at most.
#   - Prose sentences of 25 words or fewer. A numbered step is 20 words or fewer.
#   - The headings and the facts that a reader cannot find elsewhere.
#   - No personal voice, no dates of past changes, no U+2014.
#
# Limits of the check: it counts words per sentence. It cannot test the active voice, the present tense,
# or the ban on the -ing form. A reviewer checks those (rules/code-style.md, "Default register").
# A code span counts as one word. A fenced block, a heading, and a table separator are not prose.
#
# Section 0 proves each scanner fails on a fixture that breaks its rule (fail-to-fail).
#
# Usage: bash tests/test-readme.sh

set -u

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
README="$REPO_DIR/README.md"

PASS=0
FAIL=0

assert() {
	local name="$1" expected="$2" actual="$3"
	if [ "$expected" = "$actual" ]; then
		printf '  PASS  %s\n' "$name"
		PASS=$((PASS + 1))
	else
		printf '  FAIL  %s\n        expected: %s\n        actual:   %s\n' \
			"$name" "${expected:-<none>}" "${actual:-<none>}"
		FAIL=$((FAIL + 1))
	fi
}

# long_sentences <file>: print "<words> words: <sentence>" for each prose sentence over its limit.
# The limit is 25 words, and 20 words for a sentence in a numbered step.
long_sentences() {
	awk -v lim=25 -v nlim=20 '
		function emit(s, k,   a, n, max) {
			sub(/^[ \t]+/, "", s)
			sub(/[ \t]+$/, "", s)
			if (s == "") return
			n = split(s, a, /[ \t]+/)
			max = (k == "n") ? nlim : lim
			if (n > max) printf "%d words: %s\n", n, s
		}
		function flush(   t, parts, i, m) {
			if (buf == "") return
			t = buf
			gsub(/[.!?]+[ \t]+/, "&\n", t)
			m = split(t, parts, "\n")
			for (i = 1; i <= m; i++) emit(parts[i], kind)
			buf = ""
			kind = "p"
		}
		function clean(l) {
			gsub(/`[^`]*`/, "X", l)
			gsub(/\]\([^)]*\)/, "]", l)
			return l
		}
		BEGIN { fence = 0; buf = ""; kind = "p" }
		/^```/ { flush(); fence = !fence; next }
		fence { next }
		/^#/ { flush(); next }
		/^[ \t]*$/ { flush(); next }
		/^\|/ {
			flush()
			if ($0 ~ /^\|[ \t:|-]*$/) next
			n = split(clean($0), cells, "|")
			for (i = 1; i <= n; i++) emit(cells[i], "p")
			next
		}
		/^[ \t]*[0-9]+\.[ \t]/ { flush(); kind = "n"; l = $0; sub(/^[ \t]*[0-9]+\.[ \t]+/, "", l); buf = clean(l); next }
		/^[ \t]*[-*][ \t]/ { flush(); l = $0; sub(/^[ \t]*[-*][ \t]+/, "", l); buf = clean(l); next }
		{ buf = (buf == "") ? clean($0) : buf " " clean($0) }
		END { flush() }
	' "$1"
}

# missing_headings <file>: print each required "## " heading that the file lacks, one per line.
REQUIRED_HEADINGS='What you get
Requirements
Install
Verify
How it is organized
Daily use
Memory
Contribute
Troubleshooting
License'
missing_headings() {
	printf '%s\n' "$REQUIRED_HEADINGS" | while IFS= read -r h; do
		grep -qxF -- "## $h" "$1" || printf '%s\n' "$h"
	done
}

# section <file> <heading>: print the lines under "## <heading>" up to the next "## " heading.
section() {
	awk -v h="## $2" '$0 == h { on = 1; next } /^## / { on = 0 } on' "$1"
}

# words <n>: print n distinct words.
words() {
	local n="$1" out="" i=0
	while [ "$i" -lt "$n" ]; do
		out="$out w$i"
		i=$((i + 1))
	done
	printf '%s' "${out# }"
}

# ── 0. Each scanner fails on a fixture that breaks its rule (fail-to-fail) ──
echo "# 0. The scanners catch what they guard"
FIX="$(mktemp -d "${TMPDIR:-/tmp}/test-readme.XXXXXX")"
trap 'rm -rf "$FIX"' EXIT

printf '%s.\n' "$(words 25)" >"$FIX/ok25.md"
printf '%s.\n' "$(words 26)" >"$FIX/bad26.md"
assert "0.1 a prose sentence of 25 words passes" "" "$(long_sentences "$FIX/ok25.md")"
assert "0.2 a prose sentence of 26 words is reported" "26 words: $(words 26)." "$(long_sentences "$FIX/bad26.md")"
printf '1. %s.\n' "$(words 20)" >"$FIX/step20.md"
printf '1. %s.\n' "$(words 21)" >"$FIX/step21.md"
assert "0.3 a numbered step of 20 words passes" "" "$(long_sentences "$FIX/step20.md")"
assert "0.4 a numbered step of 21 words is reported" "21 words: $(words 21)." "$(long_sentences "$FIX/step21.md")"
printf '%s\n' '```' "$(words 40)" '```' "# $(words 40)" >"$FIX/code.md"
assert "0.5 a long line in a code block or a heading is not prose" "" "$(long_sentences "$FIX/code.md")"
# shellcheck disable=SC2016 # the backticks stay literal: they make a code span
printf '%s `bash -c "a b c d e f g h"` %s.\n' "$(words 12)" "$(words 11)" >"$FIX/span.md"
assert "0.6 a code span counts as one word" "" "$(long_sentences "$FIX/span.md")"
printf '%s. %s.\n' "$(words 20)" "$(words 20)" >"$FIX/two.md"
assert "0.7 two short sentences on one line are two sentences" "" "$(long_sentences "$FIX/two.md")"
printf '%s\n%s.\n' "$(words 13)" "$(words 13)" >"$FIX/wrap.md"
assert "0.8 a sentence that wraps over two lines is one sentence" "26 words: $(words 13) $(words 13)." "$(long_sentences "$FIX/wrap.md")"
printf '| a | %s. |\n|---|---|\n' "$(words 26)" >"$FIX/table.md"
assert "0.9 a long table cell is reported" "26 words: $(words 26)." "$(long_sentences "$FIX/table.md")"
printf '%s\n' '## Install' '## Verify' >"$FIX/heads.md"
assert "0.10 a file with two headings lacks the other eight" "8" "$(missing_headings "$FIX/heads.md" | wc -l | tr -d ' ')"
printf '## Install\nbash install.sh\n## Verify\nother\n' >"$FIX/sec.md"
assert "0.11 section stops at the next heading" "bash install.sh" "$(section "$FIX/sec.md" Install)"
printf 'a \342\200\224 b\n' >"$FIX/dash.md"
assert "0.12 the U+2014 check finds an em dash" 1 "$(grep -c "$(printf '\342\200\224')" "$FIX/dash.md")"

# ── 1. The size budget ─────────────────────────────────────────────────────
echo "# 1. The README fits the budget"
LINES="$(wc -l <"$README" | tr -d ' ')"
WORDS="$(wc -w <"$README" | tr -d ' ')"
assert "1.1 at most 150 lines" yes "$([ "$LINES" -le 150 ] && echo yes || echo "no ($LINES lines)")"
assert "1.2 at most 1,200 words" yes "$([ "$WORDS" -le 1200 ] && echo yes || echo "no ($WORDS words)")"

# ── 2. Plain sentences ─────────────────────────────────────────────────────
echo "# 2. Prose sentences are short"
assert "2.1 no prose sentence is over its word limit" "" "$(long_sentences "$README")"

# ── 3. Public voice ────────────────────────────────────────────────────────
echo "# 3. The voice is public and current"
assert "3.1 no U+2014 in the README" 0 "$(grep -c "$(printf '\342\200\224')" "$README")"
assert "3.2 the words personal and two machines are absent" 0 "$(grep -ciE 'personal|two machines' "$README")"
assert "3.3 no date of a past change" 0 "$(grep -cE '(19|20)[0-9]{2}-[0-9]{2}-[0-9]{2}' "$README")"
assert "3.4 the README is a title and a summary first, with no old audit section" 0 "$(grep -ciE 'audit artifacts|llm council' "$README")"

# ── 4. Structure and the facts that no other file holds ────────────────────
echo "# 4. The headings and the key facts are present"
assert "4.1 every required heading exists" "" "$(missing_headings "$README")"
assert "4.2 the title is the first line" yes "$(head -n 1 "$README" | grep -q '^# ' && echo yes || echo no)"
assert "4.3 the Install section runs install.sh" yes \
	"$([ "$(section "$README" Install | grep -c 'install\.sh')" -ge 1 ] && echo yes || echo no)"
assert "4.4 the bash pin warning names the fix" yes \
	"$([ "$(grep -c 'brew install bash' "$README")" -ge 1 ] && echo yes || echo no)"
assert "4.5 the Verify section names the doctor" yes \
	"$([ "$(section "$README" Verify | grep -c 'bootstrap-doctor\.sh')" -ge 1 ] && echo yes || echo no)"
assert "4.6 the identity step names the noreply address" yes \
	"$([ "$(grep -c 'users\.noreply\.github\.com' "$README")" -ge 1 ] && echo yes || echo no)"
assert "4.7 the Contribute section names the test command" yes \
	"$([ "$(section "$README" Contribute | grep -c 'run-all\.sh')" -ge 1 ] && echo yes || echo no)"

printf '\ntest-readme: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
