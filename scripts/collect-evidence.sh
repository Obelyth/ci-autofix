#!/usr/bin/env bash
# Turns a failed run into the smallest thing that still explains it.
#
# A build reports its cause near the top and its consequences near the bottom,
# and the middle is usually one line repeated. So the log is reduced to two
# windows: around the first error, and the tail. None of this is cacheable -
# the evidence differs every run - which makes it the one input worth being
# strict about.
set -euo pipefail

EVIDENCE="${RUNNER_TEMP}/ci-failure.md"
CONTEXT_LINES=40   # window around the first error, for the cause
TAIL_LINES=120     # end of the log, for the consequences
MAX_BYTES=60000    # hard ceiling on the whole file

# Lines that usually mark the real failure rather than its fallout.
ERROR_RE='(^|[^a-zA-Z])(error|fatal|failed|failure|exception|panic|traceback|assert|cannot|unable to|not found|undefined|unresolved|refused|denied|timed out)([^a-zA-Z]|$)|^[[:space:]]*(FAIL|ERR)|##\[error\]'

{
  echo "# Failing CI run"
  echo
  gh run view "$RUN_ID" --repo "$REPO" \
    --json displayTitle,headBranch,headSha,event,conclusion,url \
    --template '- Title: {{.displayTitle}}
- Branch: {{.headBranch}}
- Commit: {{.headSha}}
- Triggered by: {{.event}}
- Result: {{.conclusion}}
- Run: {{.url}}'
  echo
  echo
  echo "## Jobs"
  echo
  gh run view "$RUN_ID" --repo "$REPO" --json jobs \
    --jq '.jobs[] | "- \(.name): \(.conclusion)"'
  echo
  echo "## What failed"
  echo
} > "$EVIDENCE"

if ! gh run view "$RUN_ID" --repo "$REPO" --log-failed > "${RUNNER_TEMP}/raw.log" 2>/dev/null; then
  echo "_Could not download the step logs. Run \`gh run view $RUN_ID --log-failed\` to see them._" >> "$EVIDENCE"
  echo "path=$EVIDENCE" >> "$GITHUB_OUTPUT"
  exit 0
fi

total=$(wc -l < "${RUNNER_TEMP}/raw.log")

# The first error line anchors the cause window. Fall back to the top when
# nothing matches, which happens when a step dies without explaining itself.
first_err=$(grep -nEi "$ERROR_RE" "${RUNNER_TEMP}/raw.log" 2>/dev/null | head -1 | cut -d: -f1 || true)
[[ -z "$first_err" ]] && first_err=1

half=$(( CONTEXT_LINES / 2 ))
start=1
(( first_err > half )) && start=$(( first_err - half ))
end=$(( start + CONTEXT_LINES ))

{
  if (( total > CONTEXT_LINES + TAIL_LINES )); then
    echo "_The log is ${total} lines. Shown below: the first error in context, then the tail._"
    echo "_Everything else: \`gh run view ${RUN_ID} --log-failed\`._"
    echo
  fi

  echo "### Where it first went wrong (line ${first_err})"
  echo '```'
  sed -n "${start},${end}p" "${RUNNER_TEMP}/raw.log"
  echo '```'
  echo

  if (( total > end )); then
    echo "### How the job ended (last ${TAIL_LINES} lines)"
    echo '```'
    tail -n "$TAIL_LINES" "${RUNNER_TEMP}/raw.log"
    echo '```'
  fi
} >> "$EVIDENCE"

# Belt and braces: one pathological line can still blow the budget.
if [[ $(wc -c < "$EVIDENCE") -gt $MAX_BYTES ]]; then
  head -c "$MAX_BYTES" "$EVIDENCE" > "${EVIDENCE}.trim"
  printf '\n\n_(truncated at %s KB)_\n' "$((MAX_BYTES / 1000))" >> "${EVIDENCE}.trim"
  mv "${EVIDENCE}.trim" "$EVIDENCE"
fi

echo "path=$EVIDENCE" >> "$GITHUB_OUTPUT"
echo "Evidence: $(wc -c < "$EVIDENCE") bytes from a ${total}-line log."
