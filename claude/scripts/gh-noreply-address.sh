#!/usr/bin/env bash
# gh-noreply-address.sh -- print the GitHub noreply address of the signed-in gh user.
#
# Usage: bash ~/.claude/scripts/gh-noreply-address.sh
#
# Prints <id>+<login>@users.noreply.github.com and exits 0. Prints nothing, and still exits 0, when gh
# is absent, not signed in, offline, or answers with anything that is not that address.
# The reject text of noreply-email-check.sh and the warning of bootstrap-doctor.sh (check 9) call this
# script, so the command that derives the address has one home.
#
# Read-only: one GET of /user. The script needs no tool except gh and runs on bash 3.2.

ADDRESS_RE='^[0-9]+\+[A-Za-z0-9][A-Za-z0-9-]*@users\.noreply\.github\.com$'

command -v gh >/dev/null 2>&1 || exit 0
address="$(gh api user --jq '"\(.id)+\(.login)@users.noreply.github.com"' 2>/dev/null)" || exit 0
# An error body that gh prints can pass the filter and give "null+null@...", so check the shape.
if [[ "$address" =~ $ADDRESS_RE ]]; then
	printf '%s\n' "$address"
fi
exit 0
