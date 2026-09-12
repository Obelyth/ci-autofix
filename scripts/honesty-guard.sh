#!/usr/bin/env bash
# Inspects the change Claude just made and fails the job if the green tick was
# bought rather than earned. There is deliberately no override: if a fix really
# does need a test removed or a gate relaxed, a person does that, not this robot.
set -uo pipefail

FAILURES=()
note() { FAILURES+=("$1"); }

DIFF_RANGE="${BASE_SHA}..HEAD"

# --- 0. There has to be a commit, and it has to be additional history. --------
if [[ "$(git rev-parse HEAD)" == "$BASE_SHA" ]]; then
  echo "No commit was made. Nothing to check, and nothing to push."
  echo "clean=false" >> "$GITHUB_OUTPUT"
  echo "verdict=no-commit" >> "$GITHUB_OUTPUT"
  exit 1
fi

if ! git merge-base --is-ancestor "$BASE_SHA" HEAD; then
  note "History was rewritten. The starting commit \`${BASE_SHA:0:8}\` is no longer an ancestor of HEAD, which means a rebase, reset or amend dropped it. Fixes must only ever add commits."
fi

# An empty commit would push nothing, re-run the identical CI, fail in the
# identical way, and spend one of the three attempts doing it.
if git diff --quiet "$BASE_SHA" HEAD; then
  echo "The commit changes no files. Pushing it would re-run the same CI against the same code."
  echo "clean=false" >> "$GITHUB_OUTPUT"
  echo "verdict=empty-diff" >> "$GITHUB_OUTPUT"
  exit 1
fi

ADDED="$(git diff "$DIFF_RANGE" --unified=0 | grep -E '^\+' | grep -v '^+++' || true)"
FILES="$(git diff "$DIFF_RANGE" --name-status || true)"

# --- 1. Deleted test files. ---------------------------------------------------
DELETED_TESTS="$(echo "$FILES" | awk '$1 ~ /^D/ {print $2}' \
  | grep -Ei '(\.test\.|\.spec\.|(^|/)test_|_test\.|Tests?\.swift$|(^|/)tests?/)' || true)"
if [[ -n "$DELETED_TESTS" ]]; then
  note "Test files were deleted:
$(echo "$DELETED_TESTS" | sed 's/^/    - /')"
fi

# --- 2. Skip and ignore markers added. ----------------------------------------
SKIPS="$(echo "$ADDED" | grep -Ein \
  '(it|test|describe|context|suite)\.(skip|todo|failing)\b|\bxit\s*\(|\bxdescribe\s*\(|\bxtest\s*\(|@pytest\.mark\.(skip|xfail)|@unittest\.skip|\bt\.Skip\s*\(|#\[ignore\]|@Ignore\b|\.skip\s*\(|pending\s*\(' || true)"
if [[ -n "$SKIPS" ]]; then
  note "Tests were skipped or marked as expected failures:
$(echo "$SKIPS" | head -20 | sed 's/^/    /')"
fi

# --- 3. CI gates relaxed. -----------------------------------------------------
CI_TOUCHED="$(echo "$FILES" | awk '{print $NF}' | grep -E '^\.github/workflows/' || true)"
if [[ -n "$CI_TOUCHED" ]]; then
  CI_ADDED="$(git diff "$DIFF_RANGE" --unified=0 -- .github/workflows/ | grep -E '^\+' | grep -v '^+++' || true)"
  CI_REMOVED="$(git diff "$DIFF_RANGE" --unified=0 -- .github/workflows/ | grep -E '^-' | grep -v '^---' || true)"

  if echo "$CI_ADDED" | grep -Eiq 'continue-on-error:\s*true|if:\s*false|\|\|\s*true|--no-verify|--force|fail-fast:\s*false\s*#\s*disabled'; then
    note "A CI workflow was changed in a way that stops a failure from failing the build:
$(echo "$CI_ADDED" | grep -Ein 'continue-on-error:\s*true|if:\s*false|\|\|\s*true|--no-verify|--force' | head -10 | sed 's/^/    /')"
  fi
  # A removed `run:` line in CI means a check was taken out entirely.
  if echo "$CI_REMOVED" | grep -Eq '^\-\s*(- )?run:'; then
    note "A step was removed from a CI workflow. Deleting the check that caught the problem is not fixing the problem:
$(echo "$CI_REMOVED" | grep -E '^\-\s*(- )?run:' | head -10 | sed 's/^/    /')"
  fi
fi

# --- 4. Check commands hollowed out in the package manifest. ------------------
MANIFEST_ADDED="$(git diff "$DIFF_RANGE" --unified=0 -- package.json Makefile pyproject.toml \
  2>/dev/null | grep -E '^\+' | grep -v '^+++' || true)"
if echo "$MANIFEST_ADDED" | grep -Eq '"(test|lint|typecheck|build|boundaries|check)[^"]*"\s*:\s*"(true|echo[^"]*|exit 0)"'; then
  note "A check script was replaced with a command that always succeeds:
$(echo "$MANIFEST_ADDED" | grep -E '"(test|lint|typecheck|build|boundaries|check)[^"]*"\s*:\s*"(true|echo|exit 0)' | head -10 | sed 's/^/    /')"
fi

# --- 5. Local hooks disabled. -------------------------------------------------
HOOK_FILES="$(echo "$FILES" | awk '{print $NF}' | grep -Ei 'lefthook|husky|pre-commit-config|\.githooks/' || true)"
if [[ -n "$HOOK_FILES" ]]; then
  note "Git hook configuration was modified ($(echo "$HOOK_FILES" | tr '\n' ' ')). Hooks are a gate, so changing them is a human decision."
fi

# --- 6. Bypass flags introduced anywhere. ------------------------------------
BYPASS="$(echo "$ADDED" | grep -En -- '--no-verify|git push .*(--force|-f)\b|--admin\b|SKIP=|HUSKY=0|LEFTHOOK=0' || true)"
if [[ -n "$BYPASS" ]]; then
  note "A verification bypass flag was introduced:
$(echo "$BYPASS" | head -10 | sed 's/^/    /')"
fi

# --- 7. The toolkit must not edit itself. ------------------------------------
if echo "$FILES" | awk '{print $NF}' | grep -q '^\.ci-autofix/'; then
  note "The auto-fix toolkit itself was modified. It is checked out read-only and must never appear in a fix."
fi

# The same thing by name, for the case where the repo being fixed IS the toolkit.
# install.sh refuses to install a caller there, but a fork or a hand-written
# caller would not know that, and a fixer that can edit its own rules has none.
SELF="$(echo "$FILES" | awk '{print $NF}' | grep -E '(honesty-guard\.sh|guard_test\.sh|PLAYBOOK\.md|fingerprint\.sh)$' || true)"
if [[ -n "$SELF" ]]; then
  note "The fix changes the rules that judge it:
$(echo "$SELF" | sed 's/^/    - /')"
fi

# --- 8. Test coverage must not shrink. ---------------------------------------
OUT="${RUNNER_TEMP}/fingerprint-after.json" bash "$(dirname "$0")/fingerprint.sh" > /dev/null
before_cases=$(jq -r '.test_cases' "$FINGERPRINT_BEFORE")
after_cases=$(jq -r '.test_cases' "${RUNNER_TEMP}/fingerprint-after.json")
before_asserts=$(jq -r '.assertions' "$FINGERPRINT_BEFORE")
after_asserts=$(jq -r '.assertions' "${RUNNER_TEMP}/fingerprint-after.json")

if (( after_cases < before_cases )); then
  note "The number of test cases fell from $before_cases to $after_cases. Fewer tests is not a passing suite."
fi
if (( after_asserts < before_asserts )); then
  note "The number of assertions fell from $before_asserts to $after_asserts. Removing the check that failed is not a fix."
fi

# --- Verdict ------------------------------------------------------------------
{
  echo "## Honesty check"
  echo
  echo "Comparing \`${BASE_SHA:0:8}\` with the fix commit."
  echo
  echo "| Measure | Before | After |"
  echo "|---|---|---|"
  echo "| Test cases | $before_cases | $after_cases |"
  echo "| Assertions | $before_asserts | $after_asserts |"
  echo
} >> "$GITHUB_STEP_SUMMARY"

if (( ${#FAILURES[@]} > 0 )); then
  {
    echo "**Blocked.** The change would have made CI pass without fixing the cause:"
    echo
    for f in "${FAILURES[@]}"; do echo "- $f"; done
    echo
    echo "Nothing was pushed. This needs a person."
  } >> "$GITHUB_STEP_SUMMARY"

  echo "::error::Honesty check failed - the fix weakens the tests or the CI gates."
  for f in "${FAILURES[@]}"; do echo "  - $f"; done
  echo "clean=false" >> "$GITHUB_OUTPUT"
  exit 1
fi

echo "**Passed.** The fix changes the code under test, not the tests." >> "$GITHUB_STEP_SUMMARY"
echo "Honesty check passed."
echo "clean=true" >> "$GITHUB_OUTPUT"
