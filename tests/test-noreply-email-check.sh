#!/usr/bin/env bash
# tests/test-noreply-email-check.sh -- the noreply email guard (issue 40).
#
# Contract: in a repo whose root holds .require-noreply-email, the pre-commit
# dispatcher rejects a commit whose author or committer email is not a GitHub
# noreply address, and the pre-push dispatcher rejects a push that sends such a
# commit, before the test suite runs. A repo without the marker is not checked.
# SKIP_EMAIL_CHECK=1 bypasses both.
#
# Push mode skips only history that the push destination already holds. When the
# old tip of the pushed ref is unknown, the check asks the destination for its refs
# (git ls-remote on the URL that git gives to pre-push) and trusts no other remote.
# Every remote in these cases is a local bare repo, so no case uses the network.
#
# Why: on 2026-11-05 a commit with a private address reached `git push`, and
# GitHub's GH007 caught it only at the server. GH007 does not know a work email,
# so a work email would have been published.
#
# Hermetic: HOME points at a throwaway tree whose ~/.claude links into this
# checkout (tests/lib/fresh-home.sh). The real installer puts the shims into
# throwaway repos, and every commit below runs through them. The ambient
# GIT_AUTHOR_* and GIT_COMMITTER_* variables are cleared, so each case sets the
# identity it tests.
#
# Exit 0 on full pass; non-zero on any failure.

set -u

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="$REPO_DIR/claude/scripts/install-repo-hooks.sh"
PRE_PUSH="$REPO_DIR/claude/hooks/repo-pre-push.sh"
ENSURE="$REPO_DIR/claude/hooks/ensure-repo-hooks.sh"

PASS=0
FAIL=0

assert_eq() {
	local name="$1" expected="$2" actual="$3"
	if [ "$expected" = "$actual" ]; then
		printf '  PASS  %s\n' "$name"
		PASS=$((PASS + 1))
	else
		printf '  FAIL  %s\n        expected: %s\n        actual:   %s\n' "$name" "$expected" "$actual"
		FAIL=$((FAIL + 1))
	fi
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/fresh-home.sh
. "$REPO_DIR/tests/lib/fresh-home.sh"
TMP_HOME="$(TMPDIR="$WORK" fresh_home_new "$REPO_DIR")"

unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL \
	GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE SKIP_EMAIL_CHECK 2>/dev/null || true

NR='123456+octo@users.noreply.github.com'
NR2='octo@users.noreply.github.com'
BAD='a@example.com'
ZERO=0000000000000000000000000000000000000000

# make_repo <dir> <marker 0|1>: a repo with a noreply identity in its config, a
# stub tests/run-all.sh that drops .suite-ran, one initial commit, and the
# shims from the real installer. It runs in a subshell under the throwaway HOME,
# so global git settings (core.hooksPath, init.templateDir) and real hooks never
# touch the fixture or the real ~/.claude.
make_repo() (
	local dir="$1" marker="$2"
	export HOME="$TMP_HOME"
	mkdir -p "$dir/tests"
	git -C "$dir" init -q -b main
	git -C "$dir" config user.name "Octo"
	git -C "$dir" config user.email "$NR"
	# shellcheck disable=SC2016 # $(...) stays literal: it is the text of the stub script
	printf '#!/usr/bin/env bash\ntouch "$(git rev-parse --show-toplevel)/.suite-ran"\n' >"$dir/tests/run-all.sh"
	git -C "$dir" add tests/run-all.sh
	if [ "$marker" = 1 ]; then
		printf '# opt-in marker for claude/scripts/noreply-email-check.sh\n' >"$dir/.require-noreply-email"
		git -C "$dir" add .require-noreply-email
	fi
	git -C "$dir" commit -q -m init
	cd "$dir" && bash "$INSTALLER" >/dev/null 2>&1
)

# try_commit <dir> <command...>: run the command in <dir> with the throwaway
# HOME; print "accepted" when HEAD moved, "rejected" when it did not.
try_commit() {
	local dir="$1" before after
	shift
	before="$(git -C "$dir" rev-parse HEAD)"
	(cd "$dir" && env HOME="$TMP_HOME" "$@") >"$WORK/last.out" 2>&1
	after="$(git -C "$dir" rev-parse HEAD)"
	if [ "$before" = "$after" ]; then echo rejected; else echo accepted; fi
}

# run_push <dir> <stdin lines> [<remote name> <url>]: call the pre-push dispatcher the way
# git does; print its exit status. Output goes to $WORK/last.out. The default URL does not
# exist, so a case that needs the destination must pass one.
run_push() {
	local dir="$1" lines="$2"
	rm -f "$dir/.suite-ran"
	(cd "$dir" && printf '%s\n' "$lines" | HOME="$TMP_HOME" bash "$PRE_PUSH" "${3:-origin}" "${4:-$WORK/no-such-url.git}") >"$WORK/last.out" 2>&1
	echo "$?"
}

# try_push <dir> <git push args...>: run a real git push through the installed pre-push shim.
# Print "accepted", "rejected" (the check refused), or "error: <git output>".
try_push() {
	local dir="$1" rc
	shift
	(cd "$dir" && env HOME="$TMP_HOME" git push -q "$@") >"$WORK/last.out" 2>&1
	rc=$?
	if [ "$rc" -eq 0 ]; then
		echo accepted
	elif grep -q 'noreply-email-check:' "$WORK/last.out"; then
		echo rejected
	else
		echo "error: $(head -3 "$WORK/last.out" | tr '\n' ' ')"
	fi
}

new_bare() { git init -q --bare "$1"; }

# seed_dest <repo> <destination> <sha> <ref>: put a commit into a destination, with the check off.
seed_dest() {
	(cd "$1" && env HOME="$TMP_HOME" SKIP_EMAIL_CHECK=1 git push -q "$2" "$3:$4") >/dev/null 2>&1
}

R="$WORK/marked"
make_repo "$R" 1
N="$WORK/unmarked"
make_repo "$N" 0

echo "=== 1. author email at commit time ==="
assert_eq "1.1 a private author email is rejected" rejected \
	"$(try_commit "$R" GIT_AUTHOR_EMAIL="$BAD" git commit -q --allow-empty -m c11)"
assert_eq "1.2 the message names the address" 1 "$(grep -cF -- "$BAD" "$WORK/last.out")"
assert_eq "1.3 the message gives the fix" 1 "$(grep -c 'git config user.email' "$WORK/last.out")"
assert_eq "1.4 the <id>+<login> noreply shape is accepted" accepted \
	"$(try_commit "$R" GIT_AUTHOR_EMAIL="$NR" git commit -q --allow-empty -m c14)"
assert_eq "1.5 the <login> noreply shape is accepted" accepted \
	"$(try_commit "$R" GIT_AUTHOR_EMAIL="$NR2" GIT_COMMITTER_EMAIL="$NR2" git commit -q --allow-empty -m c15)"
assert_eq "1.6 a bot noreply address is accepted" accepted \
	"$(try_commit "$R" GIT_AUTHOR_EMAIL='41898282+github-actions[bot]@users.noreply.github.com' git commit -q --allow-empty -m c16)"
assert_eq "1.7 a look-alike domain is rejected" rejected \
	"$(try_commit "$R" GIT_AUTHOR_EMAIL='octo@users.noreply.github.com.evil.io' git commit -q --allow-empty -m c17)"
# Pre-commit refused the commit, so --amend would fold the next change into the previous commit.
assert_eq "1.8 a staged reject does not give the --amend hint" 0 "$(grep -c -- '--amend' "$WORK/last.out")"

echo "=== 2. committer email at commit time ==="
assert_eq "2.1 a private committer email with a noreply author is rejected" rejected \
	"$(try_commit "$R" GIT_COMMITTER_EMAIL="$BAD" git commit -q --allow-empty -m c21)"

echo "=== 3. config override on the command line ==="
assert_eq "3.1 git -c user.email=<private> is rejected" rejected \
	"$(try_commit "$R" git -c user.email="$BAD" commit -q --allow-empty -m c31)"

echo "=== 4. --author: pre-commit rejects it, and the push backstop ==="
# git exports the --author identity to the pre-commit hook, so staged mode sees it.
assert_eq "4.0 a private --author email is rejected at commit time" rejected \
	"$(try_commit "$R" git commit -q --allow-empty --author="A <$BAD>" -m c41)"
# The push case needs the commit, so it is made with the check bypassed.
try_commit "$R" SKIP_EMAIL_CHECK=1 git commit -q --allow-empty --author="A <$BAD>" -m c41b >/dev/null
assert_eq "4.1 the commit with the private --author exists for the push case" "$BAD" "$(git -C "$R" log -1 --format=%ae)"
PARENT="$(git -C "$R" rev-parse HEAD~1)"
HEAD_SHA="$(git -C "$R" rev-parse HEAD)"
assert_eq "4.2 push mode rejects the --author commit" 1 \
	"$(run_push "$R" "refs/heads/main $HEAD_SHA refs/heads/main $PARENT")"
assert_eq "4.3 the suite does not run after a reject" 0 "$([ -e "$R/.suite-ran" ] && echo 1 || echo 0)"
git -C "$R" reset -q --hard "$PARENT"

echo "=== 5. amend with a private identity ==="
assert_eq "5.1 --amend --reset-author with a private email is rejected" rejected \
	"$(try_commit "$R" git -c user.email="$BAD" commit -q --amend --allow-empty --reset-author --no-edit)"

echo "=== 6. a repo without the marker ==="
assert_eq "6.1 a private email is accepted where the repo has no marker" accepted \
	"$(try_commit "$N" GIT_AUTHOR_EMAIL='test@test.com' GIT_COMMITTER_EMAIL='test@test.com' git commit -q --allow-empty -m c61)"
NHEAD="$(git -C "$N" rev-parse HEAD)"
NPARENT="$(git -C "$N" rev-parse HEAD~1)"
assert_eq "6.2 push mode ignores a repo without the marker" 0 \
	"$(run_push "$N" "refs/heads/main $NHEAD refs/heads/main $NPARENT")"

echo "=== 7. bypass ==="
assert_eq "7.1 SKIP_EMAIL_CHECK=1 accepts a private email" accepted \
	"$(try_commit "$R" SKIP_EMAIL_CHECK=1 GIT_AUTHOR_EMAIL="$BAD" git commit -q --allow-empty -m c71)"
git -C "$R" reset -q --hard HEAD~1

echo "=== 8. push mode ==="
BASE="$(git -C "$R" rev-parse HEAD)"
try_commit "$R" SKIP_EMAIL_CHECK=1 GIT_AUTHOR_EMAIL="$BAD" git commit -q --allow-empty -m c81 >/dev/null
BADSHA="$(git -C "$R" rev-parse HEAD)"
try_commit "$R" git commit -q --allow-empty -m c82 >/dev/null
TOP="$(git -C "$R" rev-parse HEAD)"
assert_eq "8.1 a range that holds one private-email commit is rejected" 1 \
	"$(run_push "$R" "refs/heads/main $TOP refs/heads/main $BASE")"
assert_eq "8.2 the reject message names the address" 1 "$(grep -cF -- "$BAD" "$WORK/last.out")"
assert_eq "8.3 a deletion line alone is skipped" 0 \
	"$(run_push "$R" "(delete) $ZERO refs/heads/old $BADSHA")"
# The destination D1 holds the private-email commit, as a legacy commit that was pushed long ago.
# This clone has no remote-tracking ref at all (a fresh init plus remote add, before any fetch).
D1="$WORK/d1.git"
D2="$WORK/d2.git"
new_bare "$D1"
new_bare "$D2"
seed_dest "$R" "$D1" "$BADSHA" refs/heads/legacy
assert_eq "8.4 a new branch skips a commit that the destination holds, with no tracking ref" 0 \
	"$(run_push "$R" "refs/heads/topic $TOP refs/heads/topic $ZERO" origin "$D1")"
assert_eq "8.5 the suite still runs after a clean check" 1 "$([ -e "$R/.suite-ran" ] && echo 1 || echo 0)"
assert_eq "8.6 a new branch with a private-email commit that the destination lacks is rejected" 1 \
	"$(run_push "$R" "refs/heads/topic $TOP refs/heads/topic $ZERO" origin "$D2")"
assert_eq "8.7 a remote sha that the clone lacks: the destination refs decide, so a lacking destination rejects" 1 \
	"$(run_push "$R" "refs/heads/main $TOP refs/heads/main 1111111111111111111111111111111111111111" origin "$D2")"
assert_eq "8.8 a push reject gives the --amend hint for the listed commits" 1 "$(grep -c -- '--amend' "$WORK/last.out")"
assert_eq "8.7b a remote sha that the clone lacks: a destination that holds the private-email commit leaves it out" 0 \
	"$(run_push "$R" "refs/heads/main $TOP refs/heads/main 1111111111111111111111111111111111111111" origin "$D1")"
assert_eq "8.9 a known old tip needs no destination call: the URL is not read" 0 \
	"$(run_push "$R" "refs/heads/main $TOP refs/heads/main $BADSHA" origin "$WORK/no-such-url.git")"

echo "=== 9. push mode: only the destination counts ==="
# new_pushrepo <dir>: a marked repo with a good commit, a private-email commit PBAD (made with the
# check off), and a good commit on top. PBAD is the history that must not reach a destination that lacks it.
new_pushrepo() {
	make_repo "$1" 1
	try_commit "$1" SKIP_EMAIL_CHECK=1 GIT_AUTHOR_EMAIL="$BAD" git commit -q --allow-empty -m pbad >/dev/null
	PBAD="$(git -C "$1" rev-parse HEAD)"
	try_commit "$1" git commit -q --allow-empty -m ptop >/dev/null
}
fetch_remote() { (cd "$1" && env HOME="$TMP_HOME" git fetch -q "$2") >/dev/null 2>&1; }

# 9.1: a private work remote holds PBAD. The push goes to the public origin, which lacks it.
P1="$WORK/p1"
new_pushrepo "$P1"
new_bare "$WORK/work1.git"
new_bare "$WORK/origin1.git"
git -C "$P1" remote add work "$WORK/work1.git"
git -C "$P1" remote add origin "$WORK/origin1.git"
seed_dest "$P1" "$WORK/work1.git" "$PBAD" refs/heads/feature
fetch_remote "$P1" work
assert_eq "9.0 the clone has a tracking ref of the work remote that holds the private-email commit" "$PBAD" \
	"$(git -C "$P1" rev-parse --verify -q refs/remotes/work/feature)"
assert_eq "9.1 a commit that only another remote holds is still checked" rejected \
	"$(try_push "$P1" origin main:refs/heads/feature)"
assert_eq "9.2 the reject message names the address" 1 "$(grep -cF -- "$BAD" "$WORK/last.out")"
seed_dest "$P1" "$WORK/origin1.git" "$PBAD" refs/heads/legacy
assert_eq "9.3 the same push passes once the destination itself holds that commit" accepted \
	"$(try_push "$P1" origin main:refs/heads/feature)"

# 9.4: a stale tracking ref. The clone thinks origin holds PBAD. The server does not (it was deleted).
P2="$WORK/p2"
new_pushrepo "$P2"
new_bare "$WORK/origin2.git"
git -C "$P2" remote add origin "$WORK/origin2.git"
git -C "$P2" update-ref refs/remotes/origin/feature "$PBAD"
assert_eq "9.4 a stale tracking ref does not hide a commit that the destination lacks" rejected \
	"$(try_push "$P2" origin main:refs/heads/other)"

# 9.5: a push to a bare URL. No remote name exists, so git passes the URL as both arguments.
P3="$WORK/p3"
new_pushrepo "$P3"
new_bare "$WORK/url-has.git"
new_bare "$WORK/url-lacks.git"
seed_dest "$P3" "$WORK/url-has.git" "$PBAD" refs/heads/legacy
assert_eq "9.5 a push to a bare URL that lacks the commit is rejected" rejected \
	"$(try_push "$P3" "$WORK/url-lacks.git" main:refs/heads/feature)"
assert_eq "9.6 a push to a bare URL that holds the commit is accepted" accepted \
	"$(try_push "$P3" "$WORK/url-has.git" main:refs/heads/feature)"

# 9.7: a remote whose pushurl differs from its fetch url. git gives the pushurl to pre-push.
P4="$WORK/p4"
new_pushrepo "$P4"
new_bare "$WORK/fetch4.git"
new_bare "$WORK/push4.git"
git -C "$P4" remote add split "$WORK/fetch4.git"
git -C "$P4" remote set-url --push split "$WORK/push4.git"
seed_dest "$P4" "$WORK/fetch4.git" "$PBAD" refs/heads/feature
fetch_remote "$P4" split
assert_eq "9.7 a commit that only the fetch url holds is rejected on a push to the pushurl" rejected \
	"$(try_push "$P4" split main:refs/heads/feature)"
seed_dest "$P4" "$WORK/push4.git" "$PBAD" refs/heads/legacy
assert_eq "9.8 the push passes once the pushurl holds the commit" accepted \
	"$(try_push "$P4" split main:refs/heads/feature)"

# 9.9: ls-remote fails. The check cannot know what the destination holds, so it scans every pushed commit.
P5="$WORK/p5"
new_pushrepo "$P5"
PTOP5="$(git -C "$P5" rev-parse HEAD)"
assert_eq "9.9 a destination that cannot be listed: the whole history is checked" 1 \
	"$(run_push "$P5" "refs/heads/topic $PTOP5 refs/heads/topic $ZERO" origin "$WORK/no-such-url.git")"
assert_eq "9.10 the check says that it scanned everything" 1 "$(grep -c 'could not list' "$WORK/last.out")"
assert_eq "9.11 no URL (an old shim): the whole history is checked" 1 \
	"$(
		cd "$P5" && printf 'refs/heads/topic %s refs/heads/topic %s\n' "$PTOP5" "$ZERO" | HOME="$TMP_HOME" bash "$PRE_PUSH" >/dev/null 2>&1
		echo $?
	)"

# 9.12: ls-remote hangs. A wrapper git sleeps on ls-remote only. The time limit makes the check give up.
SLOW="$WORK/slowgit"
mkdir -p "$SLOW"
REAL_GIT="$(command -v git)"
# shellcheck disable=SC2016 # "$1" and "$@" stay literal: they are the text of the wrapper script
printf '#!/bin/sh\n[ "$1" = ls-remote ] && exec sleep 30\nexec "%s" "$@"\n' "$REAL_GIT" >"$SLOW/git"
chmod +x "$SLOW/git"
new_bare "$WORK/hang.git"
seed_dest "$P5" "$WORK/hang.git" "$PBAD" refs/heads/legacy
T0=$SECONDS
HANG_RC="$(
	cd "$P5" && printf 'refs/heads/topic %s refs/heads/topic %s\n' "$PTOP5" "$ZERO" \
		| env HOME="$TMP_HOME" PATH="$SLOW:$PATH" NOREPLY_LS_REMOTE_TIMEOUT=1 bash "$PRE_PUSH" origin "$WORK/hang.git" >"$WORK/last.out" 2>&1
	echo $?
)"
assert_eq "9.12 a destination that hangs: the check gives up and scans the whole history" 1 "$HANG_RC"
assert_eq "9.13 the check gave up at the time limit, not at the hang" 1 "$([ $((SECONDS - T0)) -lt 15 ] && echo 1 || echo 0)"

echo "=== 10. the pre-push shim passes the remote name and URL ==="
# git gives the remote name and URL to pre-push as $1 and $2. A shim that drops them leaves the check blind.
# Shims that are already installed hold the old line. The installer and the auto-installer must rewrite
# that one line in place and leave the rest of the hook alone.
# shellcheck disable=SC2016 # "$HOME" and "$@" stay literal: they are the text of the shim
OLD_LINE='bash "$HOME/.claude/hooks/repo-pre-push.sh"'
# shellcheck disable=SC2016 # same reason as OLD_LINE
NEW_LINE='bash "$HOME/.claude/hooks/repo-pre-push.sh" "$@"'
S1="$WORK/shim1"
make_repo "$S1" 0
assert_eq "10.1 a new shim passes all arguments to the dispatcher" 1 "$(grep -cFx -- "$NEW_LINE" "$S1/.git/hooks/pre-push")"
assert_eq "10.2 a new shim holds no line without the arguments" 0 "$(grep -cFx -- "$OLD_LINE" "$S1/.git/hooks/pre-push")"

# old_shim <dir>: a repo whose pre-push hook has the old dispatcher line between two custom lines.
old_shim() {
	make_repo "$1" 0
	printf '#!/usr/bin/env bash\necho custom-before\n%s\necho custom-after\n' "$OLD_LINE" >"$1/.git/hooks/pre-push"
	chmod +x "$1/.git/hooks/pre-push"
}
S2="$WORK/shim2"
old_shim "$S2"
S2_OUT="$(cd "$S2" && HOME="$TMP_HOME" bash "$INSTALLER" 2>&1)"
assert_eq "10.3 the installer rewrites the old line in place and keeps the custom lines" \
	"#!/usr/bin/env bash|echo custom-before|$NEW_LINE|echo custom-after" \
	"$(tr '\n' '|' <"$S2/.git/hooks/pre-push" | sed 's/|$//')"
assert_eq "10.4 the installer reports the migration" 1 "$(printf '%s\n' "$S2_OUT" | grep -c '^  migrated .*pre-push')"
assert_eq "10.5 the migrated hook is executable" 1 "$([ -x "$S2/.git/hooks/pre-push" ] && echo 1 || echo 0)"
S2_SUM="$(cksum <"$S2/.git/hooks/pre-push")"
S2_OUT2="$(cd "$S2" && HOME="$TMP_HOME" bash "$INSTALLER" 2>&1)"
assert_eq "10.6 a second run leaves the hook byte-identical and reports ok" "$S2_SUM 3" \
	"$(cksum <"$S2/.git/hooks/pre-push") $(printf '%s\n' "$S2_OUT2" | grep -c '^  ok ')"

S3="$WORK/shim3"
old_shim "$S3"
S3_ERR="$(cd "$S3" && HOME="$TMP_HOME" bash "$ENSURE" 2>&1)"
assert_eq "10.7 the auto-installer migrates an old shim although all three hooks carry their markers" 1 \
	"$(grep -cFx -- "$NEW_LINE" "$S3/.git/hooks/pre-push")"
assert_eq "10.8 the auto-installer is silent and keeps the custom lines" "|1 1" \
	"$S3_ERR|$(grep -cFx 'echo custom-before' "$S3/.git/hooks/pre-push") $(grep -cFx 'echo custom-after' "$S3/.git/hooks/pre-push")"
S3_SUM="$(cksum <"$S3/.git/hooks/pre-push")"
(cd "$S3" && HOME="$WORK/no-such-home" bash "$ENSURE" >/dev/null 2>&1)
assert_eq "10.9 a migrated shim ends the auto-installer early" "$S3_SUM" "$(cksum <"$S3/.git/hooks/pre-push")"

# A line that only starts like the dispatcher is not that line. The migration must not touch it.
S4="$WORK/shim4"
make_repo "$S4" 0
printf '#!/usr/bin/env bash\n%s || exit 1\n' "$OLD_LINE" >"$S4/.git/hooks/pre-push"
S4_SUM="$(cksum <"$S4/.git/hooks/pre-push")"
(cd "$S4" && HOME="$TMP_HOME" bash "$INSTALLER" >/dev/null 2>&1)
assert_eq "10.10 a customised dispatcher line is left alone" "$S4_SUM" "$(cksum <"$S4/.git/hooks/pre-push")"

echo "=== 11. addresses in commit message trailers ==="
# An address in a trailer is published like an author email. The commit-msg hook checks the commit that
# is about to exist. Push mode checks commits that already exist. Both run only behind the same marker.
# The scan covers every <...@...> address in any trailer. Allowed: the noreply shapes of the identity
# check, plus noreply@anthropic.com (a public no-reply address, written by tools as a Co-Authored-By).
T="$WORK/trailers"
make_repo "$T" 1
NOMSG="$(printf 'feat: x\n\nbody\n\nCo-Authored-By: Pat <pat@example.com>')"
assert_eq "11.1 a hand-written Co-Authored-By with a work address is rejected at commit time" rejected \
	"$(try_commit "$T" git commit -q --allow-empty -m "$NOMSG")"
assert_eq "11.2 the message names the trailer and the address" "1 1" \
	"$(grep -cF 'trailer "Co-Authored-By"' "$WORK/last.out") $(grep -cF -- '"pat@example.com"' "$WORK/last.out")"
assert_eq "11.3 any trailer token counts: a Reviewed-by with a work address is rejected" rejected \
	"$(try_commit "$T" git commit -q --allow-empty -m "$(printf 'feat: x\n\nbody\n\nReviewed-by: Rae <rae@example.com>')")"
assert_eq "11.4 the message names the Reviewed-by token" 1 "$(grep -cF 'trailer "Reviewed-by"' "$WORK/last.out")"
GOODMSG="$(printf 'feat: x\n\nbody\n\nCo-Authored-By: A <%s>\nCo-Authored-By: B <%s>\nCo-Authored-By: C <noreply@github.com>\nCo-Authored-By: Claude <noreply@anthropic.com>\nSigned-off-by: D <41898282+github-actions[bot]@users.noreply.github.com>' "$NR" "$NR2")"
assert_eq "11.5 noreply and Anthropic trailers pass" accepted "$(try_commit "$T" git commit -q --allow-empty -m "$GOODMSG")"
assert_eq "11.6 an address in the body, outside the trailers, is not checked" accepted \
	"$(try_commit "$T" git commit -q --allow-empty -m "$(printf 'feat: x\n\nAsk pat <pat@example.com> about this.\n\nRefs: #1')")"
assert_eq "11.7 SKIP_EMAIL_CHECK=1 bypasses the trailer check" accepted \
	"$(try_commit "$T" SKIP_EMAIL_CHECK=1 git commit -q --allow-empty -m "$NOMSG")"
git -C "$T" reset -q --hard HEAD~1

# git commit -s signs with the committer identity. A noreply identity gives a noreply sign-off. A work
# identity cannot pass pre-commit, so the work sign-off is made in an unmarked repo, and its message is
# handed to the commit-msg dispatcher of the marked repo.
assert_eq "11.8 git commit -s with a noreply identity passes" accepted \
	"$(try_commit "$T" git commit -q --allow-empty -s -m 'feat: signed')"
SG="$WORK/signer"
make_repo "$SG" 0
try_commit "$SG" GIT_COMMITTER_EMAIL=q@example.com git commit -q --allow-empty -s -m 'feat: signed' >/dev/null
git -C "$SG" log -1 --format=%B >"$WORK/signed.msg"
assert_eq "11.9 the sign-off of a work identity is in the message that git wrote" 1 "$(grep -cF 'Signed-off-by:' "$WORK/signed.msg")"
(cd "$T" && HOME="$TMP_HOME" bash "$REPO_DIR/claude/hooks/repo-commit-msg.sh" "$WORK/signed.msg") >"$WORK/last.out" 2>&1
SIGN_RC=$?
assert_eq "11.10 the commit-msg hook rejects that sign-off and names the trailer and address" "1 1 1" \
	"$SIGN_RC $(grep -cF 'trailer "Signed-off-by"' "$WORK/last.out") $(grep -cF -- '"q@example.com"' "$WORK/last.out")"

echo "--- 11b. push mode"
TBASE="$(git -C "$T" rev-parse HEAD)"
try_commit "$T" SKIP_EMAIL_CHECK=1 git commit -q --allow-empty -m "$NOMSG" >/dev/null
assert_eq "11.11 push mode rejects a pushed commit with a work address in a trailer" 1 \
	"$(run_push "$T" "refs/heads/main $(git -C "$T" rev-parse HEAD) refs/heads/main $TBASE")"
assert_eq "11.12 the push message names the trailer and the address" "1 1" \
	"$(grep -cF 'trailer "Co-Authored-By"' "$WORK/last.out") $(grep -cF -- '"pat@example.com"' "$WORK/last.out")"
assert_eq "11.13 the suite does not run after that reject" 0 "$([ -e "$T/.suite-ran" ] && echo 1 || echo 0)"
git -C "$T" reset -q --hard "$TBASE"
try_commit "$T" git commit -q --allow-empty -m "$GOODMSG" >/dev/null
assert_eq "11.14 push mode accepts noreply and Anthropic trailers" 0 \
	"$(run_push "$T" "refs/heads/main $(git -C "$T" rev-parse HEAD) refs/heads/main $TBASE")"
git -C "$T" reset -q --hard "$TBASE"
# A commit made with --no-verify and -s under a work committer identity: the sign-off reaches history.
# The identity check rejects it too, so 11.16 is the case that proves the trailer check.
try_commit "$T" GIT_COMMITTER_EMAIL=q@example.com git commit -q --no-verify --allow-empty -s -m 'feat: signed' >/dev/null
assert_eq "11.15 push mode rejects a git commit -s sign-off with a work address" 1 \
	"$(run_push "$T" "refs/heads/main $(git -C "$T" rev-parse HEAD) refs/heads/main $TBASE")"
assert_eq "11.16 the push message names the Signed-off-by trailer" 1 "$(grep -cF 'trailer "Signed-off-by"' "$WORK/last.out")"
git -C "$T" reset -q --hard "$TBASE"
# A cherry-pick copies the message, trailers included. It runs no commit-msg hook, so only push mode sees it.
git -C "$T" checkout -q -b side
printf 'side\n' >"$T/side.txt"
git -C "$T" add side.txt
try_commit "$T" SKIP_EMAIL_CHECK=1 git commit -q -m "$NOMSG" >/dev/null
git -C "$T" checkout -q main
try_commit "$T" git cherry-pick side >/dev/null
assert_eq "11.17 the cherry-picked commit carries the work trailer" 1 "$(git -C "$T" log -1 --format=%B | grep -cF 'pat@example.com')"
assert_eq "11.18 push mode rejects the cherry-picked commit" 1 \
	"$(run_push "$T" "refs/heads/main $(git -C "$T" rev-parse HEAD) refs/heads/main $TBASE")"
git -C "$T" reset -q --hard "$TBASE"

echo "--- 11c. no marker, and the dispatcher"
assert_eq "11.19 a repo without the marker accepts a work trailer" accepted \
	"$(try_commit "$N" git commit -q --allow-empty -m "$NOMSG")"
assert_eq "11.20 push mode ignores the trailer in a repo without the marker" 0 \
	"$(run_push "$N" "refs/heads/main $(git -C "$N" rev-parse HEAD) refs/heads/main $NPARENT")"
# A repo with both markers runs the message lint and the trailer check. Neither hides the other, and
# SKIP_COMMIT_LINT=1 bypasses the lint only.
B2="$WORK/both"
make_repo "$B2" 1
printf '# opt-in marker for claude/scripts/commit-msg-lint.sh\n' >"$B2/.conventional-commits"
BADBOTH="$(printf 'bad message\n\nCo-Authored-By: Pat <pat@example.com>')"
assert_eq "11.21 with both markers a bad subject and a bad trailer are rejected" rejected \
	"$(try_commit "$B2" git commit -q --allow-empty -m "$BADBOTH")"
assert_eq "11.22 the output reports the trailer and the lint rules" "1 1" \
	"$(grep -cF 'trailer "Co-Authored-By"' "$WORK/last.out") $(grep -c 'commit-msg-lint: R1' "$WORK/last.out")"
assert_eq "11.23 SKIP_COMMIT_LINT=1 does not bypass the trailer check" rejected \
	"$(try_commit "$B2" SKIP_COMMIT_LINT=1 git commit -q --allow-empty -m "$BADBOTH")"
assert_eq "11.24 a good subject with a good trailer passes both" accepted \
	"$(try_commit "$B2" git commit -q --allow-empty -m "$(printf 'feat: ok\n\nCo-Authored-By: Claude <noreply@anthropic.com>')")"

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
