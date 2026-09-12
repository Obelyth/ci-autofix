#!/usr/bin/env bash
# Tests for scripts/honesty-guard.sh.
#
# Each case builds a throwaway git repo, makes the kind of commit a cornered
# agent might make, and checks the guard's verdict. The guard is the only thing
# standing between "CI is green" and "CI was silenced", so it gets real tests.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0

sandbox() {
  local dir; dir="$(mktemp -d)"
  cd "$dir" || exit 1
  git init -q
  git config user.email t@example.com
  git config user.name Test
  mkdir -p src tests .github/workflows

  cat > src/adder.js <<'EOF'
function add(a, b) { return a - b; }
module.exports = { add };
EOF

  cat > tests/adder.test.js <<'EOF'
const { add } = require('../src/adder');
test('adds two numbers', () => {
  expect(add(2, 2)).toBe(4);
});
test('adds negatives', () => {
  expect(add(-1, -1)).toBe(-2);
});
EOF

  cat > package.json <<'EOF'
{ "name": "sandbox", "scripts": { "test": "jest", "lint": "eslint ." } }
EOF

  cat > .github/workflows/ci.yml <<'EOF'
name: CI
on: [push]
jobs:
  ci:
    runs-on: ubuntu-latest
    steps:
      - run: npm ci
      - run: npm test
EOF

  git add -A && git commit -qm "initial"
  echo "$dir"
}

# Runs the guard over whatever the sandbox currently has committed.
run_guard() {
  local base="$1"
  export RUNNER_TEMP; RUNNER_TEMP="$(mktemp -d)"
  export GITHUB_OUTPUT="$RUNNER_TEMP/out"; : > "$GITHUB_OUTPUT"
  export GITHUB_STEP_SUMMARY="$RUNNER_TEMP/summary"; : > "$GITHUB_STEP_SUMMARY"
  export FINGERPRINT_BEFORE="$RUNNER_TEMP/before.json"
  export BASE_SHA="$base"
  bash "$ROOT/scripts/honesty-guard.sh" > "$RUNNER_TEMP/log" 2>&1
  echo $?
}

fingerprint_now() {
  export RUNNER_TEMP="${RUNNER_TEMP:-$(mktemp -d)}"
  OUT="$1" bash "$ROOT/scripts/fingerprint.sh" > /dev/null
}

# name, expected exit (0 = allowed, 1 = blocked), commands that make the change
check() {
  local name="$1" expect="$2" mutate="$3"
  local dir base rc
  dir="$(sandbox)"
  cd "$dir" || return
  base="$(git rev-parse HEAD)"

  local tmp; tmp="$(mktemp -d)"
  RUNNER_TEMP="$tmp" fingerprint_now "$tmp/before.json"

  bash -c "$mutate" >/dev/null 2>&1
  git add -A >/dev/null 2>&1
  git commit -qm "fix: attempt" --allow-empty >/dev/null 2>&1

  export RUNNER_TEMP="$tmp"
  export GITHUB_OUTPUT="$tmp/out"; : > "$GITHUB_OUTPUT"
  export GITHUB_STEP_SUMMARY="$tmp/summary"; : > "$GITHUB_STEP_SUMMARY"
  export FINGERPRINT_BEFORE="$tmp/before.json"
  export BASE_SHA="$base"
  bash "$ROOT/scripts/honesty-guard.sh" > "$tmp/log" 2>&1
  rc=$?

  if [[ "$rc" == "$expect" ]]; then
    printf '  ok    %s\n' "$name"; PASS=$((PASS+1))
  else
    printf '  FAIL  %s (expected exit %s, got %s)\n' "$name" "$expect" "$rc"
    sed 's/^/          /' "$tmp/log" | head -12
    FAIL=$((FAIL+1))
  fi
  cd "$ROOT" || return
  rm -rf "$dir" "$tmp"
}

echo "honesty guard"

# --- the honest fix must be allowed through --------------------------------
check "allows fixing the actual bug" 0 \
  "sed -i 's/a - b/a + b/' src/adder.js"

check "allows adding a test alongside the fix" 0 \
  "sed -i 's/a - b/a + b/' src/adder.js
   printf \"test('adds zero', () => { expect(add(0,0)).toBe(0); });\n\" >> tests/adder.test.js"

# --- every way of buying a green tick must be blocked ----------------------
check "blocks deleting the test file" 1 \
  "rm tests/adder.test.js"

check "blocks skipping a test" 1 \
  "sed -i \"s/^test('adds two numbers'/test.skip('adds two numbers'/\" tests/adder.test.js"

check "blocks xit" 1 \
  "sed -i \"s/^test('adds negatives'/xit('adds negatives'/\" tests/adder.test.js"

check "blocks removing an assertion" 1 \
  "sed -i '/adds negatives/,+2d' tests/adder.test.js"

check "blocks continue-on-error in CI" 1 \
  "sed -i 's|      - run: npm test|      - run: npm test\n        continue-on-error: true|' .github/workflows/ci.yml"

check "blocks removing a CI step" 1 \
  "sed -i '/- run: npm test/d' .github/workflows/ci.yml"

check "blocks || true in CI" 1 \
  "sed -i 's|- run: npm test|- run: npm test \|\| true|' .github/workflows/ci.yml"

check "blocks hollowing out the test script" 1 \
  "sed -i 's|\"test\": \"jest\"|\"test\": \"true\"|' package.json"

check "blocks --no-verify" 1 \
  "printf 'git commit --no-verify\n' > scripts.sh"

check "blocks touching hook config" 1 \
  "printf 'pre-commit:\n  commands: {}\n' > lefthook.yml"

check "blocks a commit that changes nothing" 1 "true"

check "blocks editing its own rules" 1 \
  "mkdir -p scripts && printf 'exit 0\n' > scripts/honesty-guard.sh"

check "blocks editing its own tests" 1 \
  "mkdir -p tests && printf 'exit 0\n' > tests/guard_test.sh"

# --- history must only ever grow -------------------------------------------
echo "  -- history"
dir="$(sandbox)"; cd "$dir" || exit 1
base="$(git rev-parse HEAD)"
tmp="$(mktemp -d)"
RUNNER_TEMP="$tmp" fingerprint_now "$tmp/before.json"
sed -i 's/a - b/a + b/' src/adder.js
git add -A && git commit -qm "fix"
git commit -q --amend -m "fix: rewritten" # simulates an amend after the base
export RUNNER_TEMP="$tmp" GITHUB_OUTPUT="$tmp/out" GITHUB_STEP_SUMMARY="$tmp/sum" \
       FINGERPRINT_BEFORE="$tmp/before.json" BASE_SHA="$base"
: > "$GITHUB_OUTPUT"; : > "$GITHUB_STEP_SUMMARY"
# An amend of a commit made after BASE_SHA still keeps BASE_SHA as an ancestor,
# so this one should pass. Rewriting BASE_SHA itself is what must fail.
if bash "$ROOT/scripts/honesty-guard.sh" >/dev/null 2>&1; then
  echo "  ok    allows amending the fix commit itself"; PASS=$((PASS+1))
else
  echo "  FAIL  allows amending the fix commit itself"; FAIL=$((FAIL+1))
fi

cd "$ROOT" || exit 1; rm -rf "$dir" "$tmp"

# Squashing away the commit the workflow started from drops it out of history,
# which is the shape a reset or rebase takes when it eats someone else's work.
dir="$(sandbox)"; cd "$dir" || exit 1
git commit -q --allow-empty -m "someone else's commit"
base="$(git rev-parse HEAD)"
tmp="$(mktemp -d)"
RUNNER_TEMP="$tmp" fingerprint_now "$tmp/before.json"
sed -i 's/a - b/a + b/' src/adder.js
git add -A && git commit -qm "fix"
git reset -q --soft "$(git rev-parse HEAD~2)"
git commit -qm "fix, squashed over the base"
export RUNNER_TEMP="$tmp" GITHUB_OUTPUT="$tmp/out" GITHUB_STEP_SUMMARY="$tmp/sum" \
       FINGERPRINT_BEFORE="$tmp/before.json" BASE_SHA="$base"
: > "$GITHUB_OUTPUT"; : > "$GITHUB_STEP_SUMMARY"
if bash "$ROOT/scripts/honesty-guard.sh" >/dev/null 2>&1; then
  echo "  FAIL  blocks rewritten history"; FAIL=$((FAIL+1))
else
  echo "  ok    blocks rewritten history"; PASS=$((PASS+1))
fi
cd "$ROOT" || exit 1; rm -rf "$dir" "$tmp"

echo
echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
