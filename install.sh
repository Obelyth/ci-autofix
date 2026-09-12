#!/usr/bin/env bash
# Installs the CI Auto-Fix caller workflow into every repo on both accounts.
#
#   ./install.sh --dry-run          show what would change, touch nothing
#   ./install.sh                    install or refresh everywhere
#   ./install.sh --only-missing     only repos that do not have it yet (the sweep)
#   ./install.sh --repo owner/name  just one repo
#
# Safe to run repeatedly. A repo whose caller already matches is left alone.
set -euo pipefail
cd "$(dirname "$0")"

# --- configuration ------------------------------------------------------------
# Real values live in config.sh, which is gitignored, or in the environment when
# this runs in CI. Nothing account-specific is committed. See config.example.sh.
CALLER_PATH=".github/workflows/ci-autofix.yml"

OWNERS=()
ANTHROPIC_ORG_ID="${ANTHROPIC_ORG_ID:-}"
ANTHROPIC_SERVICE_ACCOUNT_ID="${ANTHROPIC_SERVICE_ACCOUNT_ID:-}"
ANTHROPIC_WORKSPACE_ID="${ANTHROPIC_WORKSPACE_ID:-}"

# shellcheck source=/dev/null
[[ -f config.sh ]] && source config.sh

# Federation rules may arrive as "owner=fdrl_... owner=fdrl_..." in one env var,
# so CI can pass them without naming any account in a public workflow file.
if [[ -n "${CI_AUTOFIX_FEDERATION_RULES:-}" ]]; then
  for pair in $CI_AUTOFIX_FEDERATION_RULES; do
    [[ "$pair" == *=* ]] || continue
    key="${pair%%=*}"
    printf -v "FEDERATION_RULE_${key//[^a-zA-Z0-9]/_}" '%s' "${pair#*=}"
  done
fi

# Owners may also arrive as a space-separated env var, which is how the sweep
# workflow passes them.
if (( ${#OWNERS[@]} == 0 )) && [[ -n "${CI_AUTOFIX_OWNERS:-}" ]]; then
  read -ra OWNERS <<< "$CI_AUTOFIX_OWNERS"
fi
if (( ${#OWNERS[@]} == 0 )); then
  echo "No owners configured. Copy config.example.sh to config.sh and fill it in," >&2
  echo "or set CI_AUTOFIX_OWNERS=\"org-one org-two\"." >&2
  exit 2
fi

# Workflows that must never trigger the fixer.
#
# Two reasons a workflow is excluded. Either watching it would loop - our own
# caller, the @claude workflow - or it is a policy guard whose whole job is to
# fail when a rule is broken, and "fixing" that works against whoever wrote it.
#
# A repo can also opt any workflow out by putting this line in the file:
#   # ci-autofix: ignore
EXCLUDE_NAMES=("CI Auto-Fix" "Claude Code" "Claude")

# Only workflows that answer "does this code work" are watched. The rest fail
# for reasons a code change in the repo cannot honestly fix:
#   policy guards   fail on purpose when a rule is broken
#   deploys         a red deploy is a decision, not a bug to patch
#   scanners        usually token or config, and silently "fixing" a security
#                   scan is the wrong shape
#   metadata checks PR titles and descriptions are written by people
EXCLUDE_NAME_PATTERNS=(
  "block-*" "*guard*" "*-policy" "require-*" "deny-*"
  "*auto-merge*" "*labeler*" "*stale*" "*assign*"
  "*deploy*" "*pages*" "*sweep*"
  "*sonar*" "*slsa*" "*provenance*" "*scorecard*" "*codeql*" "*dependency intelligence*"
  "*description check*" "*commitlint*" "*conventional*"
)

# The toolkit never watches itself: here the honesty guard is ordinary source,
# so a fixer pointed at this repo could edit the very rules meant to stop it.
self="${GITHUB_REPOSITORY:-}"
if [[ -z "$self" ]]; then
  self="$(git config --get remote.origin.url 2>/dev/null \
    | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##' || true)"
fi
SKIP_REPOS=("$self")

DRY_RUN=false; ONLY_MISSING=false; SINGLE_REPO=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true ;;
    --only-missing) ONLY_MISSING=true ;;
    --repo) SINGLE_REPO="$2"; shift ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
  shift
done

say() { printf '%s\n' "$*"; }
declare -A ORG_SECRETS=()
FEDERATION_CONFIGURED=""
[[ -n "$ANTHROPIC_ORG_ID" ]] && FEDERATION_CONFIGURED=1

# --- which repos ---------------------------------------------------------------
list_repos() {
  if [[ -n "$SINGLE_REPO" ]]; then echo "$SINGLE_REPO"; return; fi
  for o in "${OWNERS[@]}"; do
    gh repo list "$o" --limit 200 --json nameWithOwner,isArchived \
      --jq '.[] | select(.isArchived | not) | .nameWithOwner'
  done
}

# --- the workflows in a repo that are worth watching ---------------------------
# workflow_run matches on a workflow's `name:` field, not its filename, so each
# candidate file has to be read to find out what it calls itself.
watched_workflows() {
  local repo="$1" names=() name f x files body
  files="$(gh api "repos/$repo/contents/.github/workflows" --jq '.[].name' 2>/dev/null || true)"
  [[ -z "$files" ]] && return 0
  while IFS= read -r f; do
    [[ "$f" =~ \.(yml|yaml)$ ]] || continue
    [[ "$f" == "ci-autofix.yml" || "$f" == "claude.yml" ]] && continue
    body="$(gh api "repos/$repo/contents/.github/workflows/$f" --jq '.content' 2>/dev/null | base64 -d 2>/dev/null || true)"
    [[ -z "$body" ]] && continue
    grep -qiE '^[[:space:]]*#[[:space:]]*ci-autofix:[[:space:]]*ignore' <<< "$body" && continue
    name="$(grep -m1 -E '^name:' <<< "$body" | sed -E 's/^name:[[:space:]]*//; s/^"//; s/"$//; s/^'"'"'//; s/'"'"'$//' || true)"
    [[ -z "$name" ]] && continue
    for x in "${EXCLUDE_NAMES[@]}"; do
      [[ "$name" == "$x" ]] && continue 2
    done
    for x in "${EXCLUDE_NAME_PATTERNS[@]}"; do
      # shellcheck disable=SC2053
      [[ "${name,,}" == ${x,,} ]] && continue 2
    done
    names+=("$name")
  done <<< "$files"
  (( ${#names[@]} )) || return 0
  printf '%s\n' "${names[@]}" | sort -u
}

# --- render the caller for one repo --------------------------------------------
render() {
  local owner="$1" default_branch="$2"; shift 2
  # Owner names may contain hyphens, which are not legal in a variable name.
  local rule_var="FEDERATION_RULE_${owner//[^a-zA-Z0-9]/_}"
  local rule="${!rule_var:-}"
  local json_list protected
  json_list="$(printf '%s\n' "$@" | jq -R . | jq -sc .)"
  # The default branch is always protected, and so are main and master wherever
  # they exist. Deduplicated, because the default branch is usually main.
  protected="$(printf '%s\n' main master "$default_branch" | sort -u | paste -sd,)"
  sed -e "s|__WORKFLOWS__|$json_list|" -e "s|__PROTECTED__|\"$protected\"|" \
      -e "s|__FED_RULE__|$rule|" -e "s|__FED_ORG__|$ANTHROPIC_ORG_ID|" \
      -e "s|__FED_SVC__|$ANTHROPIC_SERVICE_ACCOUNT_ID|" \
      -e "s|__FED_WS__|$ANTHROPIC_WORKSPACE_ID|" \
      -e "s|__TOOLKIT_REPO__|$self|g" caller.template.yml
}

# --- write it ------------------------------------------------------------------
install_into() {
  local repo="$1"
  local default_branch existing existing_sha desired content msg branch base branch_sha existing_pr
  local -a wf args

  default_branch="$(gh repo view "$repo" --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null || true)"
  if [[ -z "$default_branch" ]]; then say "  skip - empty repo or unreadable"; return; fi

  mapfile -t wf < <(watched_workflows "$repo")
  if (( ${#wf[@]} == 0 )); then say "  skip - no CI workflows to watch"; return; fi

  desired="$(render "${repo%%/*}" "$default_branch" "${wf[@]}")"
  existing="$(gh api "repos/$repo/contents/$CALLER_PATH?ref=$default_branch" --jq '.content' 2>/dev/null | base64 -d 2>/dev/null || true)"
  existing_sha="$(gh api "repos/$repo/contents/$CALLER_PATH?ref=$default_branch" --jq '.sha' 2>/dev/null || true)"

  if [[ -n "$existing" ]] && $ONLY_MISSING; then say "  already installed"; return; fi
  if [[ "$existing" == "$desired" ]]; then say "  up to date - watching: ${wf[*]}"; return; fi

  if [[ -n "$existing" ]]; then msg="ci: refresh CI Auto-Fix watched workflows"
  else msg="ci: add CI Auto-Fix"; fi
  say "  ${msg#ci: } - watching: ${wf[*]}"
  $DRY_RUN && return

  content="$(printf '%s' "$desired" | base64 -w0)"
  args=(-f "message=$msg" -f "content=$content" -f "branch=$default_branch")
  [[ -n "$existing_sha" ]] && args+=(-f "sha=$existing_sha")

  if gh api -X PUT "repos/$repo/contents/$CALLER_PATH" "${args[@]}" >/dev/null 2>&1; then
    say "    committed to $default_branch"
    return
  fi

  # Repos that require a pull request for every change land it that way instead.
  branch="ci/autofix-install"
  base="$(gh api "repos/$repo/git/ref/heads/$default_branch" --jq '.object.sha' 2>/dev/null || true)"
  [[ -z "$base" ]] && { say "    FAILED - cannot read $default_branch"; return; }
  gh api -X POST "repos/$repo/git/refs" -f "ref=refs/heads/$branch" -f "sha=$base" >/dev/null 2>&1 || true
  # The file may already exist on the fallback branch from an earlier run, and
  # the API refuses an update without that branch's own blob sha. Looking it up
  # on the default branch - where the file usually does not exist yet - is not
  # the same thing.
  branch_sha="$(gh api "repos/$repo/contents/$CALLER_PATH?ref=$branch" --jq '.sha' 2>/dev/null || true)"
  args=(-f "message=$msg" -f "content=$content" -f "branch=$branch")
  [[ -n "$branch_sha" ]] && args+=(-f "sha=$branch_sha")
  if gh api -X PUT "repos/$repo/contents/$CALLER_PATH" "${args[@]}" >/dev/null 2>&1; then
    existing_pr="$(gh pr list -R "$repo" --head "$branch" --state open --json number --jq '.[0].number // empty' 2>/dev/null || true)"
    if [[ -n "$existing_pr" ]]; then
      say "    updated pull request #$existing_pr - this repo requires them, and it is waiting on a merge"
    else
      gh pr create -R "$repo" --base "$default_branch" --head "$branch" \
        --title "$msg" --body "Installs the CI Auto-Fix caller. See https://github.com/$self" >/dev/null 2>&1 || true
      say "    opened a pull request - this repo requires them"
    fi
  else
    say "    FAILED - could not write $CALLER_PATH"
  fi
}

# --- secrets -------------------------------------------------------------------
# An organization can hold secrets centrally; a personal account cannot, so each
# of its repos needs its own. Report only what is actually missing.
report_secrets() {
  local repo="$1" owner="${1%%/*}" names org_names
  org_names="${ORG_SECRETS[$owner]-unset}"
  if [[ "$org_names" == "unset" ]]; then
    org_names="$(gh secret list --org "$owner" --json name --jq '[.[].name] | join(",")' 2>/dev/null || true)"
    ORG_SECRETS[$owner]="$org_names"
  fi
  names="$(gh secret list -R "$repo" --json name --jq '[.[].name] | join(",")' 2>/dev/null || true)"
  names="${names},${org_names}"

  if [[ -n "$FEDERATION_CONFIGURED" ]]; then
    :  # federation needs no stored credential
  elif [[ "$names" != *CLAUDE_CODE_OAUTH_TOKEN* && "$names" != *ANTHROPIC_API_KEY* ]]; then
    say "  MISSING: CLAUDE_CODE_OAUTH_TOKEN or ANTHROPIC_API_KEY - the fixer cannot run"
  fi
  [[ "$names" != *CI_AUTOFIX_TOKEN* ]] && say "  MISSING: CI_AUTOFIX_TOKEN - fixes land, but CI will not re-run on its own"
  return 0
}

# --- go ------------------------------------------------------------------------
if $DRY_RUN; then say "DRY RUN - nothing will be changed."; say ""; fi

while IFS= read -r repo; do
  [[ -z "$repo" ]] && continue
  skip=false
  for r in "${SKIP_REPOS[@]}"; do [[ "$repo" == "$r" ]] && skip=true; done
  if $skip; then say "$repo"; say "  skip - the toolkit does not watch itself"; continue; fi
  say "$repo"
  install_into "$repo"
  report_secrets "$repo"
done < <(list_repos)

say ""
for o in "${OWNERS[@]}"; do
  out="$(gh secret list --org "$o" --json name,visibility --jq '.[] | "  \(.name) [\(.visibility)]"' 2>/dev/null || true)"
  [[ -n "$out" ]] && { say "Org secrets on $o, covering every repo in it:"; say "$out"; }
done
