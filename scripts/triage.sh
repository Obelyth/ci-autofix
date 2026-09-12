#!/usr/bin/env bash
# Decides whether this failure is one we should try to fix, and which attempt it is.
# Writes proceed / skip_reason / attempt / branch / protected / pr_number to GITHUB_OUTPUT.
set -euo pipefail

out() { printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"; }
stop() { out proceed false; out skip_reason "$1"; echo "SKIP: $1"; exit 0; }

out branch "$BRANCH"

# 0. Is there anything to run Claude with? Checking here costs one runner second
#    and says plainly what is wrong, instead of spending a whole fix job to reach
#    a credential error and then filing a handoff that guesses at three causes.
if [[ "${HAS_CLAUDE_CREDENTIAL:-true}" != "true" ]]; then
  stop "Neither \`CLAUDE_CODE_OAUTH_TOKEN\` nor \`ANTHROPIC_API_KEY\` is set for this repo, so there is nothing to diagnose the failure with. On Obelyth these are org secrets; on a personal repo each one has to be set individually. Note that \`gh secret set\` reads the value from stdin unless you pass \`--body\`, so a non-interactive run can store an empty secret that still shows up in \`gh secret list\`."
fi

# 1. Branch patterns we never touch. Checkpoints, the orphan graphify context
#    branch, merge-queue temporaries, and our own fix branches.
IFS=',' read -ra patterns <<< "$SKIP_BRANCHES"
for p in "${patterns[@]}"; do
  p="$(printf '%s' "$p" | xargs)"
  [[ -z "$p" ]] && continue
  # shellcheck disable=SC2053
  if [[ "$BRANCH" == $p ]]; then
    stop "Branch \`$BRANCH\` matches the skip pattern \`$p\`."
  fi
done

if [[ "$SKIP_DEPENDABOT" == "true" && "$BRANCH" == dependabot/* ]]; then
  stop "Branch \`$BRANCH\` is a dependabot branch and skip_dependabot is on."
fi

# 2. Is the branch one we are allowed to push to directly?
protected=false
IFS=',' read -ra prot <<< "$PROTECTED_BRANCHES"
for p in "${prot[@]}"; do
  p="$(printf '%s' "$p" | xargs)"
  [[ "$BRANCH" == "$p" ]] && protected=true
done
out protected "$protected"

# 3. Which attempt is this? Count auto-fix commits sitting consecutively at the
#    tip of the branch. A human commit on top resets the count to zero, so a
#    branch someone is actively working on always gets a fresh budget.
n=0
for sha in $(git rev-list -n 25 HEAD); do
  if git log -1 --format='%B' "$sha" | grep -q '^CI-Autofix-Attempt:'; then
    n=$((n + 1))
  else
    break
  fi
done
attempt=$((n + 1))
out attempt "$attempt"

if (( attempt > MAX_ATTEMPTS )); then
  stop "Already made $n consecutive auto-fix commits on \`$BRANCH\` (limit $MAX_ATTEMPTS). Handing this to a human rather than guessing again."
fi

# 4. Is there a pull request open for this branch? Used for where to comment.
pr=$(gh pr list --repo "$REPO" --head "$BRANCH" --state open \
      --json number --jq '.[0].number // empty' 2>/dev/null || true)
out pr_number "${pr:-}"

out proceed true
out skip_reason ""
echo "Proceeding. branch=$BRANCH attempt=$attempt protected=$protected pr=${pr:-none}"
