#!/usr/bin/env bash
# tests/test-install-hostkeys.sh -- verify install.sh --hostkeys-only (wire_github_hostkeys, D-012).
#
# Why this matters: on a fresh machine with the SSH git protocol, a plugin clone from GitHub fails
# because ~/.ssh/known_hosts has no github.com entry. The installer may append the GitHub host keys,
# but only when the keys it fetched match the fingerprints that the same gh api meta response lists.
# A wrong write here would trust a key that GitHub did not publish.
#
# Safety: every run uses a throwaway HOME and a stub gh first on PATH. The stub answers only the three
# calls the installer makes and fails on any other argument. The suite never reads or writes the real
# HOME and never reaches the network. ssh-keygen reads the passwd home and ignores $HOME, so every
# ssh-keygen call here passes an explicit -f path.
#
# Env override, used for the fail-to-fail check:
#   INSTALL_SH   path of the installer under test
#
# Usage: bash tests/test-install-hostkeys.sh        (COV=1 adds line coverage on bash 4.1 or later)

set -u

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="${INSTALL_SH:-$REPO_DIR/install.sh}"

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

yesno() {
	if "$@"; then echo yes; else echo no; fi
}

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/test-install-hostkeys.XXXXXX")"
trap 'rm -rf "$TMPD"' EXIT

if [ -n "${COV:-}" ]; then
	# shellcheck source-path=SCRIPTDIR
	# shellcheck source=lib/cov.sh
	. "$REPO_DIR/tests/lib/cov.sh"
	cov_begin "$TMPD/cov.log"
fi

# ---- Fixture keys (made at test time) --------------------------------------
# Three keys: two that GitHub "publishes" in the fixture and one that it does not.
mkdir -p "$TMPD/keys"
ssh-keygen -q -t ed25519 -N '' -C '' -f "$TMPD/keys/ed" >/dev/null
ssh-keygen -q -t ecdsa -b 256 -N '' -C '' -f "$TMPD/keys/ec" >/dev/null
ssh-keygen -q -t ed25519 -N '' -C '' -f "$TMPD/keys/other" >/dev/null

# pubkey <name>: "type base64" without the comment. fp <name>: the fingerprint as the API prints it
# (no SHA256: prefix).
pubkey() { awk '{print $1, $2}' "$TMPD/keys/$1.pub"; }
fp() { ssh-keygen -lf "$TMPD/keys/$1.pub" | awk '{print $2}' | sed 's/^SHA256://'; }

# The meta document that the stub serves. Shape follows the GitHub API: ssh_keys is a list and
# ssh_key_fingerprints is an object.
META="$TMPD/meta.json"
META_BAD="$TMPD/meta-bad.json"
META_EXTRA="$TMPD/meta-extra.json"
jq -n --arg k1 "$(pubkey ed)" --arg k2 "$(pubkey ec)" --arg f1 "$(fp ed)" --arg f2 "$(fp ec)" \
	'{ssh_keys: [$k1, $k2], ssh_key_fingerprints: {SHA256_ED25519: $f1, SHA256_ECDSA: $f2}}' >"$META"
# Same keys, but one fingerprint belongs to a key that GitHub did not list.
jq -n --arg k1 "$(pubkey ed)" --arg k2 "$(pubkey ec)" --arg f1 "$(fp ed)" --arg f2 "$(fp other)" \
	'{ssh_keys: [$k1, $k2], ssh_key_fingerprints: {SHA256_ED25519: $f1, SHA256_ECDSA: $f2}}' >"$META_BAD"
# A third key in ssh_keys that has no fingerprint in the list.
jq -n --arg k1 "$(pubkey ed)" --arg k2 "$(pubkey ec)" --arg k3 "$(pubkey other)" --arg f1 "$(fp ed)" --arg f2 "$(fp ec)" \
	'{ssh_keys: [$k1, $k2, $k3], ssh_key_fingerprints: {SHA256_ED25519: $f1, SHA256_ECDSA: $f2}}' >"$META_EXTRA"

# ---- Stub gh ----------------------------------------------------------------
# Accepts exactly: config get git_protocol --host github.com (the value for github.com);
# config get git_protocol (the global value); api meta --jq .ssh_keys[]; api meta --jq .ssh_key_fingerprints[].
# STUB_PROTOCOL is the github.com value; empty means the key is unset (exit 1).
# STUB_GLOBAL_PROTOCOL is the global value (default https). STUB_FAIL=1 makes every api call fail.
STUB="$TMPD/stub"
mkdir -p "$STUB"
cat >"$STUB/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
	"config get git_protocol --host github.com")
		[ -n "${STUB_PROTOCOL:-}" ] || exit 1
		echo "$STUB_PROTOCOL"
		;;
	"config get git_protocol")
		echo "${STUB_GLOBAL_PROTOCOL:-https}"
		;;
	"api meta --jq .ssh_keys[]" | "api meta --jq .ssh_key_fingerprints[]")
		[ -z "${STUB_FAIL:-}" ] || {
			echo "stub gh: simulated API failure" >&2
			exit 1
		}
		jq -r "$4" "$STUB_META"
		;;
	*)
		echo "stub gh: unexpected arguments: $*" >&2
		exit 64
		;;
esac
EOF
chmod +x "$STUB/gh"

# new_home: an empty HOME with no .ssh folder.
new_home() { mktemp -d "$TMPD/home.XXXXXX"; }

# The installer reads the origin remote of the repo that it sits in. The real checkout has whatever origin
# the machine uses, so each run uses a copy of the installer inside a throwaway repo with a known origin.
# make_repo <name> [origin-url]: print the path of the installer copy. No URL means no origin remote.
make_repo() {
	mkdir -p "$TMPD/repo-$1"
	git init -q "$TMPD/repo-$1"
	cp "$INSTALL" "$TMPD/repo-$1/install.sh"
	if [ -n "${2:-}" ]; then git -C "$TMPD/repo-$1" remote add origin "$2"; fi
	printf '%s\n' "$TMPD/repo-$1/install.sh"
}
INSTALL_HTTPS="$(make_repo https https://github.com/example/dotfiles.git)"
INSTALL_SSH="$(make_repo ssh git@github.com:example/dotfiles.git)"
INSTALL_SSHURL="$(make_repo sshurl ssh://git@github.com/example/dotfiles.git)"
INSTALL_NOORIGIN="$(make_repo noorigin)"

# run_keys <home>: run the mode with the stub first on PATH. OUT holds all output; RC the exit code.
# Variables PROTO (github.com value, default ssh), PROTO_GLOBAL (global value, default https), META_FILE
# (default $META), GH_FAIL, and RUN_INSTALL (default the https-origin copy) tune the run.
run_keys() {
	OUT="$(HOME="$1" PATH="$STUB:$PATH" STUB_PROTOCOL="${PROTO-ssh}" STUB_GLOBAL_PROTOCOL="${PROTO_GLOBAL:-https}" \
		STUB_META="${META_FILE:-$META}" STUB_FAIL="${GH_FAIL:-}" "$BASH" "${RUN_INSTALL:-$INSTALL_HTTPS}" --hostkeys-only 2>&1)"
	RC=$?
}

# keys_in <known_hosts file>: number of github.com lines.
keys_in() { grep -c '^github\.com ' "$1" 2>/dev/null || true; }
# found <home>: yes when ssh-keygen finds github.com in the throwaway known_hosts file.
found() {
	if ssh-keygen -F github.com -f "$1/.ssh/known_hosts" >/dev/null 2>&1; then echo yes; else echo no; fi
}
# mode_of <path>: the ls permission string, for example drwx------.
# shellcheck disable=SC2012 # ls -ld is the one permission string that BSD and GNU both print the same way
mode_of() { ls -ld "$1" | cut -c1-10; }

echo "--- 1. keys are absent: the installer writes them"
H1="$(new_home)"
run_keys "$H1"
assert_eq "1.1 exit code is 0" 0 "$RC"
assert_eq "1.2 github.com is found in known_hosts" yes "$(found "$H1")"
assert_eq "1.3 two key lines are written" 2 "$(keys_in "$H1/.ssh/known_hosts")"
assert_eq "1.4 the ed25519 key text is exact" "github.com $(pubkey ed)" "$(grep ' ssh-ed25519 ' "$H1/.ssh/known_hosts")"
assert_eq "1.5 the new .ssh folder has mode 700" "drwx------" "$(mode_of "$H1/.ssh")"
assert_eq "1.6 the output reports the write" 1 "$(printf '%s\n' "$OUT" | grep -c '^  add  github.com host keys (2 keys)')"
assert_eq "1.7 the output shows the ED25519 fingerprint" "1" \
	"$(printf '%s\n' "$OUT" | grep -cF "ED25519 fingerprint: SHA256:$(fp ed)")"

echo "--- 2. a second run writes nothing and prints no add line"
SUM1="$(cksum <"$H1/.ssh/known_hosts")"
run_keys "$H1"
assert_eq "2.1 exit code is 0" 0 "$RC"
assert_eq "2.2 known_hosts is identical" "$SUM1" "$(cksum <"$H1/.ssh/known_hosts")"
assert_eq "2.3 no add line" 0 "$(printf '%s\n' "$OUT" | grep -c '^  add ')"
assert_eq "2.4 an ok line says the key is present" 1 "$(printf '%s\n' "$OUT" | grep -c '^  ok   github.com host key already')"

echo "--- 3. fingerprints do not match: nothing is written"
H3="$(new_home)"
META_FILE="$META_BAD" run_keys "$H3"
assert_eq "3.1 exit code is 0 (the installer never aborts here)" 0 "$RC"
assert_eq "3.2 no .ssh folder is created" no "$(yesno test -e "$H3/.ssh")"
assert_eq "3.3 the output says nothing was written" 1 "$(printf '%s\n' "$OUT" | grep -c '^  skip  .*differ.*Nothing written')"
H3B="$(new_home)"
META_FILE="$META_EXTRA" run_keys "$H3B"
assert_eq "3.4 an extra key without a fingerprint also writes nothing" no "$(yesno test -e "$H3B/.ssh")"

echo "--- 4. a github.com entry exists: nothing is written"
H4="$(new_home)"
mkdir -m 755 "$H4/.ssh"
printf 'github.com %s\n' "$(pubkey other)" >"$H4/.ssh/known_hosts"
SUM4="$(cksum <"$H4/.ssh/known_hosts")"
run_keys "$H4"
assert_eq "4.1 exit code is 0" 0 "$RC"
assert_eq "4.2 known_hosts is identical" "$SUM4" "$(cksum <"$H4/.ssh/known_hosts")"
assert_eq "4.3 an existing .ssh folder keeps its mode" "drwxr-xr-x" "$(mode_of "$H4/.ssh")"

echo "--- 5. protocol is https: skip"
H5="$(new_home)"
PROTO=https run_keys "$H5"
assert_eq "5.1 exit code is 0" 0 "$RC"
assert_eq "5.2 nothing is created" no "$(yesno test -e "$H5/.ssh")"
assert_eq "5.3 the output names both signals" 1 \
	"$(printf '%s\n' "$OUT" | grep -c '^  skip  no host key needed: gh protocol for github.com is "https", origin remote is https')"
H5B="$(new_home)"
PROTO="" run_keys "$H5B"
assert_eq "5.4 an unset protocol also skips" no "$(yesno test -e "$H5B/.ssh")"
assert_eq "5.5 an unset protocol is named as unset" 1 "$(printf '%s\n' "$OUT" | grep -c 'gh protocol for github.com is "unset"')"

echo "--- 6. gh is not installed: skip"
H6="$(new_home)"
OUT="$(HOME="$H6" PATH="/usr/bin:/bin" "$BASH" "$INSTALL" --hostkeys-only 2>&1)"
RC=$?
assert_eq "6.1 exit code is 0" 0 "$RC"
assert_eq "6.2 nothing is created" no "$(yesno test -e "$H6/.ssh")"
assert_eq "6.3 the output says gh is missing" 1 "$(printf '%s\n' "$OUT" | grep -c '^  skip  gh not found')"

echo "--- 7. gh fails: skip"
H7="$(new_home)"
GH_FAIL=1 run_keys "$H7"
assert_eq "7.1 exit code is 0" 0 "$RC"
assert_eq "7.2 nothing is created" no "$(yesno test -e "$H7/.ssh")"
assert_eq "7.3 the output says the keys could not be read" 1 "$(printf '%s\n' "$OUT" | grep -c '^  skip  gh could not read')"

echo "--- 8. a known_hosts file without a final newline"
H8="$(new_home)"
mkdir -m 700 "$H8/.ssh"
printf 'example.org ssh-ed25519 AAAAexample' >"$H8/.ssh/known_hosts"
run_keys "$H8"
assert_eq "8.1 exit code is 0" 0 "$RC"
assert_eq "8.2 the old line is intact" "example.org ssh-ed25519 AAAAexample" "$(sed -n 1p "$H8/.ssh/known_hosts")"
assert_eq "8.3 the new lines start on their own lines" 2 "$(keys_in "$H8/.ssh/known_hosts")"
assert_eq "8.4 github.com is found" yes "$(found "$H8")"

echo "--- 9. a write that fails does not abort the installer"
H9="$(new_home)"
printf 'not a folder\n' >"$H9/.ssh"
run_keys "$H9"
assert_eq "9.1 exit code is 0" 0 "$RC"
assert_eq "9.2 the output says the file could not be written" 1 "$(printf '%s\n' "$OUT" | grep -c '^  skip  could not write')"
assert_eq "9.3 the blocking file is untouched" "not a folder" "$(cat "$H9/.ssh")"

echo "--- 10. usage and wiring"
OUT="$(HOME="$H1" "$BASH" "$INSTALL" --bogus 2>&1)"
RC=$?
assert_eq "10.1 an unknown mode exits 2" 2 "$RC"
assert_eq "10.2 the usage line lists --hostkeys-only" 1 "$(printf '%s\n' "$OUT" | grep -c -e '--hostkeys-only')"
assert_eq "10.3 the full install calls wire_github_hostkeys once" 1 "$(grep -c '^wire_github_hostkeys$' "$INSTALL")"

# The machine needs the key when gh uses SSH for github.com, or when the origin remote of the repo is an
# SSH URL. gh keeps a global value and one for the host. The host value wins (issue 16): a global https
# with a github.com ssh value still means SSH. Before the fix the installer read only the global value.
echo "--- 11. the signals that make a host key necessary"
H11A="$(new_home)"
PROTO=ssh PROTO_GLOBAL=https run_keys "$H11A"
assert_eq "11.1 global https, github.com ssh: the keys are written" 2 "$(keys_in "$H11A/.ssh/known_hosts")"
H11B="$(new_home)"
PROTO=https PROTO_GLOBAL=ssh run_keys "$H11B"
assert_eq "11.2 global ssh, github.com https, https origin: nothing is written" no "$(yesno test -e "$H11B/.ssh")"
H11C="$(new_home)"
PROTO=https RUN_INSTALL="$INSTALL_SSH" run_keys "$H11C"
assert_eq "11.3 github.com https, origin git@github.com: the keys are written" 2 "$(keys_in "$H11C/.ssh/known_hosts")"
H11D="$(new_home)"
PROTO=https RUN_INSTALL="$INSTALL_SSHURL" run_keys "$H11D"
assert_eq "11.4 github.com https, origin ssh://git@github.com: the keys are written" 2 "$(keys_in "$H11D/.ssh/known_hosts")"
H11E="$(new_home)"
PROTO=https RUN_INSTALL="$INSTALL_NOORIGIN" run_keys "$H11E"
assert_eq "11.5 github.com https and no origin remote: nothing is written" no "$(yesno test -e "$H11E/.ssh")"
assert_eq "11.6 the skip line says there is no origin" 1 "$(printf '%s\n' "$OUT" | grep -c 'origin remote is none')"
H11F="$(new_home)"
PROTO=https RUN_INSTALL="$INSTALL_SSH" META_FILE="$META_BAD" run_keys "$H11F"
assert_eq "11.7 an SSH origin does not bypass the fingerprint check" no "$(yesno test -e "$H11F/.ssh")"

if [ -n "${COV:-}" ]; then
	cov_end
	cov_report "$INSTALL"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
