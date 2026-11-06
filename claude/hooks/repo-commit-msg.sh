#!/usr/bin/env bash
# repo-commit-msg.sh -- stable dispatcher for repo commit-msg hooks
#
# Repos call this single file via their .git/hooks/commit-msg. Git passes the
# commit message file as argument 1.
#
# The hook runs two opt-in checks. Each has its own marker file in the working tree
# at the repo root (the file need not be tracked by git), and each is independent:
#   - .conventional-commits   runs commit-msg-lint.sh, which checks the message
#     format. Other repos use other commit conventions (decision D-005).
#   - .require-noreply-email  runs noreply-email-check.sh message, which rejects a
#     trailer (Co-Authored-By, Signed-off-by, and so on) that lists an address that
#     is not a GitHub noreply address.
# The hook runs both checks that apply, then returns 1 if either failed, so the
# user sees every problem at once. In a repo with neither marker it exits 0.
#
# A check is skipped when:
#   - the lint: SKIP_COMMIT_LINT=1 is set, or $HOME/.claude/scripts/commit-msg-lint.sh
#     does not exist,
#   - the email check: SKIP_EMAIL_CHECK=1 is set (the script itself reads it), or
#     $HOME/.claude/scripts/noreply-email-check.sh does not exist.
# Missing tooling must never block a commit. SKIP_COMMIT_LINT does not skip the
# email check, and SKIP_EMAIL_CHECK does not skip the lint.
#
# Stable path (repos reference this; never rename it):
#   bash "$HOME/.claude/hooks/repo-commit-msg.sh" "$1"
#
# Bypass flags (for the user only):
#   SKIP_COMMIT_LINT=1 git commit  -- skip the message lint
#   SKIP_EMAIL_CHECK=1 git commit  -- skip the noreply email check

set -u

# Outside a repo, root is empty and each marker test fails, so the hook exits 0.
root=$(git rev-parse --show-toplevel 2>/dev/null)
rc=0

lint="$HOME/.claude/scripts/commit-msg-lint.sh"
if [ "${SKIP_COMMIT_LINT:-0}" != "1" ] && [ -f "$root/.conventional-commits" ] && [ -f "$lint" ]; then
	bash "$lint" "${1:-}" || rc=$?
fi

email_check="$HOME/.claude/scripts/noreply-email-check.sh"
if [ -f "$root/.require-noreply-email" ] && [ -f "$email_check" ]; then
	bash "$email_check" message "${1:-}" || rc=$?
fi

exit "$rc"
