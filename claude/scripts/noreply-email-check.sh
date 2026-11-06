#!/usr/bin/env bash
# noreply-email-check.sh -- reject a commit identity or a trailer address that is not a GitHub noreply address.
#
# Opt-in: runs only in a repo whose root holds the file .require-noreply-email.
# Elsewhere it exits 0, so a work repo keeps its work address.
#
# Modes:
#   staged  (repo-pre-commit.sh) checks the identity that the next commit uses:
#           git var GIT_AUTHOR_IDENT and GIT_COMMITTER_IDENT. These read the
#           environment, the -c options, and the config.
#   push    (repo-pre-push.sh) reads git's pre-push lines on stdin and checks the
#           author and committer email of every commit that the push sends. This
#           also covers commits that never ran pre-commit: --no-verify, merges,
#           rebases, and cherry-picks. Usage: push <remote name> <url>. Git gives
#           both to pre-push. A commit that the destination already holds is not
#           checked. When the old tip of the pushed ref is unknown (a new branch,
#           or a sha that the clone lacks), the check runs git ls-remote on the URL
#           and skips the commits that the advertised refs reach and the clone
#           holds. It never trusts the refs of another remote. If ls-remote fails or
#           runs past NOREPLY_LS_REMOTE_TIMEOUT seconds (default 15), the check
#           skips nothing and scans every pushed commit.
#   message (repo-commit-msg.sh) checks the trailers of the message file that git
#           gives to commit-msg. Usage: message <file>.
#
# Both push and message also check every <...@...> address in any trailer of the
# message (Co-Authored-By, Signed-off-by, Reviewed-by, and so on). An address in
# the body outside the trailers is not checked.
#
# Accepted: <id>+<login>@users.noreply.github.com, <login>@users.noreply.github.com
# (a [bot] suffix allowed), and noreply@github.com (commits made on GitHub).
# A trailer may also list noreply@anthropic.com, a public no-reply address that
# tools write as a Co-Authored-By. The identity check does not accept it.
#
# A reject prints the fix. With a signed-in gh it shows the derived address (from
# gh-noreply-address.sh) in a command to run as is. Without one it shows the steps
# to find the address. It never tells anyone to amend.
#
# Bypass: SKIP_EMAIL_CHECK=1. Known limit: git commit --no-verify and git push
# --no-verify skip this check.
#
# Runs under git, outside the harness bash pin, so it stays bash 3.2-safe.

set -euo pipefail

MODE="${1:-}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ "${SKIP_EMAIL_CHECK:-0}" = "1" ] && exit 0
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
[ -f "$ROOT/.require-noreply-email" ] || exit 0

NOREPLY_RE='^([0-9]+\+)?[A-Za-z0-9][A-Za-z0-9-]*(\[bot\])?@users\.noreply\.github\.com$'
bad=0
bad_id=0
bad_trailer=0

check() { # <what> <address> [trailer]: report the address and set bad when it is not noreply
	[ "$2" = "noreply@github.com" ] && return 0
	[[ "$2" =~ $NOREPLY_RE ]] && return 0
	if [ "${3:-}" = trailer ]; then
		printf 'noreply-email-check: %s lists "%s", which is not a GitHub noreply address.\n' "$1" "$2" >&2
		bad_trailer=1
	else
		printf 'noreply-email-check: %s uses "%s", which is not a GitHub noreply address.\n' "$1" "$2" >&2
		bad_id=1
	fi
	bad=1
}

# check_trailer_line <where> <trailer line>: check each <...@...> address in one trailer line.
check_trailer_line() {
	local token="${2%%:*}" addr
	while IFS= read -r addr; do
		[ -n "$addr" ] || continue
		addr="${addr#<}"
		addr="${addr%>}"
		[ "$addr" = "noreply@anthropic.com" ] && continue
		check "$1 trailer \"$token\"" "$addr" trailer
	done <<EOF
$(printf '%s\n' "$2" | grep -o '<[^<>]*@[^<>]*>' || true)
EOF
}

# destination_tips <url>: print each commit that the destination advertises and this clone holds.
# Print nothing when ls-remote fails or runs too long. The caller then checks every pushed commit.
destination_tips() {
	local url="$1" out pid ticks sha type
	if [ -z "$url" ]; then
		printf 'noreply-email-check: could not list the refs of the destination (no URL); checking every pushed commit.\n' >&2
		return 0
	fi
	out="$(mktemp)" || return 0
	GIT_TERMINAL_PROMPT=0 git ls-remote -- "$url" >"$out" 2>/dev/null &
	pid=$!
	ticks=$((${NOREPLY_LS_REMOTE_TIMEOUT:-15} * 10))
	while kill -0 "$pid" 2>/dev/null; do
		if [ "$ticks" -le 0 ]; then
			kill "$pid" 2>/dev/null || true
			break
		fi
		sleep 0.1
		ticks=$((ticks - 1))
	done
	if wait "$pid" 2>/dev/null; then
		cut -f1 "$out" | git cat-file --batch-check='%(objectname) %(objecttype)' | while read -r sha type; do
			if [ "$type" = commit ]; then printf '%s\n' "$sha"; fi
		done
	else
		printf 'noreply-email-check: could not list the refs of "%s"; checking every pushed commit.\n' "$url" >&2
	fi
	rm -f "$out"
	return 0
}

case "$MODE" in
	staged)
		for field in GIT_AUTHOR_IDENT GIT_COMMITTER_IDENT; do
			# An unknown identity gives an empty email, which check rejects.
			email="$(git var "$field" 2>/dev/null || true)"
			email="${email#*<}"
			check "the next commit's $field" "${email%%>*}"
		done
		;;
	push)
		ZERO_SHA=0000000000000000000000000000000000000000
		DEST_URL="${3:-}"
		DEST_LOADED=0
		DEST_TIPS=""
		while read -r _local_ref local_sha _remote_ref remote_sha; do
			case "$local_sha" in "" | "$ZERO_SHA") continue ;; esac
			# Skip what the destination has: its old tip when this clone holds it, else the commits behind its refs.
			if [ "$remote_sha" != "$ZERO_SHA" ] && git cat-file -e "$remote_sha^{commit}" 2>/dev/null; then
				known="$remote_sha"
			else
				if [ "$DEST_LOADED" -eq 0 ]; then
					DEST_TIPS="$(destination_tips "$DEST_URL")"
					DEST_LOADED=1
				fi
				known="$DEST_TIPS"
			fi
			commits="$(
				{
					printf '%s\n' "$local_sha"
					for tip in $known; do printf '^%s\n' "$tip"; done
				} | git log --format='@@%H %ae %ce%n%(trailers:only,unfold)' --stdin
			)"
			# One "@@<sha> <author> <committer>" line per commit, then its trailer lines. A trailer
			# starts with a word and a colon, so no trailer line starts with "@@".
			while IFS= read -r line; do
				case "$line" in
					@@*)
						rest="${line#@@}"
						sha="${rest%% *}"
						rest="${rest#* }"
						check "commit ${sha:0:12} (author)" "${rest%% *}"
						check "commit ${sha:0:12} (committer)" "${rest#* }"
						;;
					"") ;;
					*) check_trailer_line "commit ${sha:0:12}" "$line" ;;
				esac
			done <<EOF
$commits
EOF
		done
		;;
	message)
		[ -f "${2:-}" ] || {
			echo "Usage: noreply-email-check.sh message <file>" >&2
			exit 2
		}
		trailers="$(git interpret-trailers --parse <"$2")"
		while IFS= read -r line; do
			[ -n "$line" ] || continue
			check_trailer_line "the commit message" "$line"
		done <<EOF
$trailers
EOF
		;;
	*)
		echo "Usage: noreply-email-check.sh <staged|push|message>" >&2
		exit 2
		;;
esac

if [ "$bad" -eq 1 ]; then
	if [ "$bad_id" -eq 1 ]; then
		# The address of the signed-in gh user, or nothing. gh-noreply-address.sh is the one home of the command.
		derived="$(bash "$HERE/gh-noreply-address.sh" 2>/dev/null || true)"
		printf 'This repo requires a GitHub noreply address (.require-noreply-email).\n' >&2
		if [ -n "$derived" ]; then
			printf 'Your address, from the signed-in gh account, is %s. Set it for this repo:\n' "$derived" >&2
			printf '  git config user.email %s\n' "$derived" >&2
		else
			printf 'To find your noreply address, use one of these steps:\n' >&2
			printf '  1. Run gh auth login, then run this command again.\n' >&2
			printf '  2. Open https://github.com/settings/emails and copy your noreply address.\n' >&2
			printf 'It has the form <id>+<login>@users.noreply.github.com. Set it for this repo:\n' >&2
			printf '  git config user.email <id>+<login>@users.noreply.github.com\n' >&2
		fi
		if [ "$MODE" = push ]; then
			printf 'This changes new commits only. Each commit listed above keeps its address.\n' >&2
			printf 'To publish those commits, rewrite them. A rewrite changes history, so the owner decides.\n' >&2
		else
			printf 'Then run git commit again.\n' >&2
		fi
	fi
	if [ "$bad_trailer" -eq 1 ]; then
		printf 'This repo requires noreply addresses (.require-noreply-email), also in trailers.\n' >&2
		printf 'Remove the trailer line, or use a noreply address in it.\n' >&2
		if [ "$MODE" = push ]; then
			printf 'Each commit listed above keeps its trailer. To publish those commits, rewrite them. The owner decides.\n' >&2
		else
			printf 'Then run git commit again.\n' >&2
		fi
	fi
	printf 'Agents: show this fix to the user, and ask the user before you change any identity. Never change the global email.\n' >&2
	printf 'Bypass for one command (owner only): SKIP_EMAIL_CHECK=1\n' >&2
fi
exit "$bad"
