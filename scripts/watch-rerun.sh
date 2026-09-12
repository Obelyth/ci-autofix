#!/usr/bin/env bash
# Waits for the CI run that the fix push started, and reports how it went.
# A red result is not an error here: the workflow_run trigger fires again and
# the next attempt picks up where this one left off, until the attempt cap.
set -uo pipefail

DEADLINE=$(( $(date +%s) + WAIT_MINUTES * 60 ))
echo "Watching for a run of '$WORKFLOW_NAME' on $BRANCH at ${SHA:0:8}."

run_json=""
while (( $(date +%s) < DEADLINE )); do
  run_json="$(gh run list --branch "$BRANCH" --limit 20 \
    --json headSha,status,conclusion,name,url,databaseId \
    --jq "[.[] | select(.headSha == \"$SHA\" and .name == \"$WORKFLOW_NAME\")] | .[0] // empty" 2>/dev/null || true)"
  if [[ -n "$run_json" ]]; then
    status="$(jq -r '.status' <<< "$run_json")"
    [[ "$status" == "completed" ]] && break
    echo "  run is $status ..."
  else
    echo "  no run yet ..."
  fi
  sleep 20
done

if [[ -z "$run_json" ]]; then
  echo "::warning::No CI run appeared for ${SHA:0:8} within ${WAIT_MINUTES} minutes."
  {
    echo "## Re-run"
    echo
    echo "No CI run started for this commit. That usually means \`CI_AUTOFIX_TOKEN\` is missing, since pushes made with the built-in token do not start new runs."
  } >> "$GITHUB_STEP_SUMMARY"
  exit 0
fi

conclusion="$(jq -r '.conclusion' <<< "$run_json")"
url="$(jq -r '.url' <<< "$run_json")"

{
  echo "## Re-run"
  echo
  if [[ "$conclusion" == "success" ]]; then
    echo "Green. [$WORKFLOW_NAME]($url) passed on the fixed commit."
  else
    echo "[$WORKFLOW_NAME]($url) finished as \`$conclusion\`. The next attempt starts automatically."
  fi
} >> "$GITHUB_STEP_SUMMARY"

echo "Re-run concluded: $conclusion ($url)"
