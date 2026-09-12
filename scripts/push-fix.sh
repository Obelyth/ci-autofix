#!/usr/bin/env bash
# Pushes the fix. Never with --force, and never straight at a protected branch.
set -euo pipefail

# A push made with the built-in token deliberately starts no new workflow run,
# so the green tick would never appear. PUSH_TOKEN closes that loop.
#
# It is checked against the shape of a GitHub token - at least 30 characters of
# letters, digits and underscores - because an optional credential must never be
# able to fail the run, and a secret set by accident holds anything at all. A
# value with a colon in it read as a port number and killed the push.
#
# The credential goes in a header rather than the remote URL, which is what
# actions/checkout does: a URL has to be parsed, a header does not.
HAS_PUSH_TOKEN=false
GIT_AUTH=()
if [[ "$PUSH_TOKEN" =~ ^[A-Za-z0-9_]{30,}$ ]]; then
  GIT_AUTH=(-c "http.https://github.com/.extraheader=Authorization: Basic $(
    printf 'x-access-token:%s' "$PUSH_TOKEN" | base64 -w0)")
  HAS_PUSH_TOKEN=true
elif [[ -n "$PUSH_TOKEN" ]]; then
  echo "::warning::CI_AUTOFIX_TOKEN is set but is not shaped like a GitHub token, so it was ignored. Pushing with the built-in token instead, which will not start a new CI run."
fi

# Wrapper so every push in this script uses the credential when there is one.
gitpush() { git "${GIT_AUTH[@]}" push "$@"; }

SHA="$(git rev-parse HEAD)"
echo "sha=$SHA" >> "$GITHUB_OUTPUT"

SUBJECT="$(git log -1 --format='%s')"
BODY="$(git log -1 --format='%b')"

if [[ "$PROTECTED" == "true" ]]; then
  # main and friends are a release surface. A fix for them goes through review.
  FIX_BRANCH="claude/ci-autofix/${BRANCH//\//-}-${GITHUB_RUN_ID}"
  git checkout -b "$FIX_BRANCH"
  gitpush origin "$FIX_BRANCH"

  PR_URL="$(gh pr create \
    --base "$BRANCH" --head "$FIX_BRANCH" \
    --title "$SUBJECT" \
    --body "$(printf '%s\n\n---\n\nCI on `%s` failed and this is the fix. Opened as a pull request rather than pushed directly, because `%s` is a protected branch.\n\nThe checks below ran against this branch before it was pushed, and the honesty check confirmed no test or CI gate was weakened.\n' "$BODY" "$BRANCH" "$BRANCH")")"

  echo "pushed=true" >> "$GITHUB_OUTPUT"
  echo "pushed_branch=$FIX_BRANCH" >> "$GITHUB_OUTPUT"
  { echo "## Pushed"; echo; echo "Opened $PR_URL against the protected branch \`$BRANCH\`."; } >> "$GITHUB_STEP_SUMMARY"
  exit 0
fi

# Someone may have pushed while we worked. Rebase would rewrite their history,
# so refuse instead and let the next run start from their commit.
git fetch origin "$BRANCH"
if [[ "$(git rev-parse "origin/$BRANCH")" != "$BASE_SHA" ]]; then
  echo "::warning::\`$BRANCH\` moved while the fix was being prepared. Not pushing; the next CI failure will start again from the new head."
  { echo "## Not pushed"; echo; echo "\`$BRANCH\` moved on while this ran, so the fix was dropped rather than layered onto someone else's commit."; } >> "$GITHUB_STEP_SUMMARY"
  echo "pushed=false" >> "$GITHUB_OUTPUT"
  exit 0
fi

gitpush origin "HEAD:$BRANCH"
echo "pushed=true" >> "$GITHUB_OUTPUT"
echo "pushed_branch=$BRANCH" >> "$GITHUB_OUTPUT"

if [[ -n "${PR_NUMBER:-}" ]]; then
  gh pr comment "$PR_NUMBER" --body "$(printf '### CI fixed automatically\n\n%s\n\n%s\n\nCommit `%s`. The honesty check confirmed no test or CI gate was weakened, and the suite passed in the runner before this was pushed.\n' "$SUBJECT" "$BODY" "${SHA:0:8}")"
fi

{
  echo "## Pushed"
  echo
  echo "Commit \`${SHA:0:8}\` on \`$BRANCH\`."
} >> "$GITHUB_STEP_SUMMARY"

if [[ "${HAS_PUSH_TOKEN}" != "true" ]]; then
  echo "::warning::CI_AUTOFIX_TOKEN is not set, so this push will not start a new CI run. The fix is verified but the branch needs a manual re-run to show green."
  { echo; echo "> \`CI_AUTOFIX_TOKEN\` is not set on this repo, so GitHub will not start a fresh CI run for this push. Re-run CI by hand to see the green tick."; } >> "$GITHUB_STEP_SUMMARY"
fi
