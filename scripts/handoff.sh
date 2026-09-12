#!/usr/bin/env bash
# Called when the fix job did not succeed. Says plainly what was tried, what
# stopped it, and that nothing was pushed - then gets out of the way.
set -euo pipefail

case "$FIX_RESULT" in
  failure) headline="CI Auto-Fix stopped without pushing" ;;
  cancelled) headline="CI Auto-Fix was cancelled" ;;
  *) headline="CI Auto-Fix did not complete" ;;
esac

BODY="$(cat <<EOF
### ${headline}

Attempt ${ATTEMPT} of ${MAX_ATTEMPTS} on \`${BRANCH}\`.

- Failing CI run: ${FAILED_RUN_URL}
- Auto-fix run: ${FIX_RUN_URL}

Nothing was pushed. The usual reasons, in order of likelihood:

1. The honesty check blocked the change because it would have made CI pass by weakening a test or a CI gate rather than by fixing the cause.
2. The checks still failed in the runner after the fix.
3. The cause is not something a code change in this repo can fix, for example a missing secret, an expired token, or an outage at a service CI depends on.

The auto-fix run above says which. This one needs a person.
EOF
)"

if [[ -n "${PR_NUMBER:-}" ]]; then
  gh pr comment "$PR_NUMBER" --body "$BODY"
  echo "Commented on PR #${PR_NUMBER}."
  exit 0
fi

# No pull request, so use an issue - but only one per branch, kept up to date.
MARKER="<!-- ci-autofix-handoff:${BRANCH} -->"
# GitHub's search tokenises, so `in:body ci-autofix-handoff:feature/foo` also
# matches an issue for `feature/foo-bar`. Match the marker exactly instead.
EXISTING="$(gh issue list --state open --limit 100 --json number,body 2>/dev/null \
  | jq -r --arg m "$MARKER" '[.[] | select(.body | contains($m))] | .[0].number // empty' 2>/dev/null || true)"

if [[ -n "$EXISTING" ]]; then
  gh issue comment "$EXISTING" --body "$BODY"
  echo "Commented on existing issue #${EXISTING}."
else
  gh issue create \
    --title "CI is red on \`${BRANCH}\` and auto-fix could not fix it" \
    --body "${BODY}

${MARKER}"
  echo "Opened a handoff issue."
fi
