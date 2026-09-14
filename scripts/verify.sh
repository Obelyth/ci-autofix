#!/usr/bin/env bash
# Independently re-runs the repo's own checks inside the runner. Claude is asked
# to do this too; this step is here so the push is gated on a result the workflow
# saw for itself rather than on a claim.
set -uo pipefail

detect_setup() {
  [[ -n "${SETUP_COMMAND:-}" ]] && { echo "$SETUP_COMMAND"; return; }
  [[ -f bun.lockb || -f bun.lock ]] && { echo "bun install --frozen-lockfile"; return; }
  [[ -f pnpm-lock.yaml ]] && { echo "pnpm install --frozen-lockfile"; return; }
  [[ -f yarn.lock ]] && { echo "yarn install --frozen-lockfile"; return; }
  [[ -f package-lock.json ]] && { echo "npm ci --ignore-scripts"; return; }
  [[ -f uv.lock ]] && { echo "uv sync --frozen"; return; }
  [[ -f poetry.lock ]] && { echo "poetry install"; return; }
  [[ -f requirements.txt ]] && { echo "pip install -r requirements.txt"; return; }
  [[ -f go.mod ]] && { echo "go mod download"; return; }
  [[ -f Cargo.toml ]] && { echo "cargo fetch"; return; }
  echo ""
}

detect_test() {
  [[ -n "${TEST_COMMAND:-}" ]] && { echo "$TEST_COMMAND"; return; }
  if [[ -f package.json ]]; then
    # Run the same gates the CI workflow runs, in the same order, skipping any
    # script this repo does not define.
    cmds=()
    for s in lint typecheck boundaries test build; do
      if jq -e --arg s "$s" '.scripts[$s] // empty' package.json >/dev/null 2>&1; then
        cmds+=("npm run $s --if-present")
      fi
    done
    (( ${#cmds[@]} )) && { printf '%s\n' "${cmds[@]}"; return; }
  fi
  [[ -f pyproject.toml || -d tests ]] && { echo "python -m pytest -q"; return; }
  [[ -f go.mod ]] && { echo "go test ./..."; return; }
  [[ -f Cargo.toml ]] && { echo "cargo test"; return; }
  [[ -f Makefile ]] && grep -qE '^test:' Makefile && { echo "make test"; return; }
  echo ""
}

SETUP="$(detect_setup)"
mapfile -t CHECKS < <(detect_test)

if (( ${#CHECKS[@]} == 0 )); then
  echo "::warning::Could not work out how to run this repo's checks, so the fix was not independently verified here."
  echo "summary=not verified locally (no check command found)" >> "$GITHUB_OUTPUT"
  echo "verified=false" >> "$GITHUB_OUTPUT"
  exit 0
fi

if [[ -n "$SETUP" ]]; then
  echo "::group::$SETUP"
  eval "$SETUP" || { echo "::error::Dependency install failed: $SETUP"; exit 1; }
  echo "::endgroup::"
fi

PASSED=()
for c in "${CHECKS[@]}"; do
  echo "::group::$c"
  if eval "$c"; then
    PASSED+=("$c")
    echo "::endgroup::"
  else
    echo "::endgroup::"

    # Was this already failing before the fix?
    #
    # A repo's own CI can provide things this job cannot. cortex is the case that
    # taught us: several of its suites need a sibling checkout of a private repo,
    # which its CI does in a separate job with a scoped token. Running the whole
    # command here fails those tests no matter how good the fix is, and blaming
    # the fix for it is simply wrong - it reports a false negative and throws away
    # correct work.
    #
    # So on failure, and only on failure, re-run the same command at the commit we
    # started from. If it failed there too, the cause predates the fix.
    echo "::group::checking whether \`$c\` already failed before the fix"
    baseline_failed=false
    if git stash push -q --include-untracked -m ci-autofix-verify 2>/dev/null; then
      if git checkout -q "$BASE_SHA" -- . 2>/dev/null; then
        eval "$c" >/dev/null 2>&1 || baseline_failed=true
        git checkout -q HEAD -- . 2>/dev/null || true
      fi
      git stash pop -q 2>/dev/null || true
    fi
    echo "::endgroup::"

    if $baseline_failed; then
      echo "::warning::\`$c\` also fails at ${BASE_SHA:0:8}, before the fix. The cause predates this change and is not something the fix broke."
      {
        echo "## Verification"
        echo
        echo "\`$c\` fails — but it also fails at \`${BASE_SHA:0:8}\`, before the fix."
        echo
        echo "So this is not the fix's doing. Most often it means the suite needs"
        echo "something this job cannot provide that the repository's own CI does:"
        echo "a service, a scoped token, or a sibling checkout done in another job."
        echo
        echo "Nothing was pushed, because green was never demonstrated here."
      } >> "$GITHUB_STEP_SUMMARY"
      echo "verified=false" >> "$GITHUB_OUTPUT"
      echo "preexisting=true" >> "$GITHUB_OUTPUT"
      exit 1
    fi

    echo "::error::Still failing after the fix: $c"
    {
      echo "## Verification"
      echo
      echo "\`$c\` still fails, and it passed at \`${BASE_SHA:0:8}\`. Nothing was pushed."
    } >> "$GITHUB_STEP_SUMMARY"
    echo "verified=false" >> "$GITHUB_OUTPUT"
    exit 1
  fi
done

SUMMARY="$(printf '%s; ' "${PASSED[@]}" | sed 's/; $//')"
{
  echo "## Verification"
  echo
  echo "All checks pass in the runner:"
  echo
  for c in "${PASSED[@]}"; do echo "- \`$c\`"; done
} >> "$GITHUB_STEP_SUMMARY"

echo "summary=$SUMMARY" >> "$GITHUB_OUTPUT"
echo "verified=true" >> "$GITHUB_OUTPUT"
