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
    echo "::error::Still failing after the fix: $c"
    {
      echo "## Verification"
      echo
      echo "\`$c\` still fails. Nothing was pushed."
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
