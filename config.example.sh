#!/usr/bin/env bash
# Copy to config.sh and fill in. config.sh is gitignored - nothing here belongs
# in a public repository, even though none of it is secret.
#
# Every value below is an identifier, not a credential. They are kept out of the
# repo because they name your accounts, not because knowing them grants anything.

# GitHub accounts to install into. An org or a user, one per entry.
OWNERS=(your-org your-username)

# --- Anthropic workload identity federation (optional) ------------------------
# Leave every value empty to authenticate with a stored CLAUDE_CODE_OAUTH_TOKEN
# or ANTHROPIC_API_KEY secret instead. Filling them in switches to federation:
# the run's GitHub OIDC token is exchanged for a short-lived Anthropic token and
# nothing is stored anywhere. Setup is in README.md.

ANTHROPIC_ORG_ID=""              # Console -> Settings -> Organization
ANTHROPIC_SERVICE_ACCOUNT_ID=""  # svac_... from Settings -> Service accounts
ANTHROPIC_WORKSPACE_ID=""        # wrkspc_... - needed only when the rule spans
                                 # more than one workspace

# One federation rule per GitHub account, named FEDERATION_RULE_<owner>.
# The rule matches the OIDC subject of the repo whose CI failed, and that subject
# carries the account name, so a single rule cannot serve two accounts.
FEDERATION_RULE_your_org=""       # fdrl_...
FEDERATION_RULE_your_username=""  # fdrl_...
