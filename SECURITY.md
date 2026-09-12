# Security

## What this software is allowed to do

Installed, CI Auto-Fix can read your repositories, commit to a branch, open a
pull request, and comment on issues and pull requests. It runs a language model
over your source code and your CI logs.

Treat that the way you would treat any bot with write access. The design keeps
the blast radius small on purpose:

- **It never pushes to a protected branch.** Those get a pull request.
- **It never force pushes**, rebases, or rewrites history. A fix only adds commits.
- **It stops after three attempts** on a branch and asks for a person.
- **It skips forks.** Only same-repository branches are touched, so a pull request
  from a stranger cannot make it run.
- **It cannot weaken your tests or your CI configuration.** See the guard table in
  the README. There is no override flag.

## Credentials

**Prefer workload identity federation.** Nothing is stored: the run's GitHub OIDC
token is exchanged for a short-lived Anthropic token. Scope the federation rule to
`job_workflow_ref` so only this reusable workflow can mint one — not every
workflow in every repository you own.

If you use a stored `ANTHROPIC_API_KEY` or `CLAUDE_CODE_OAUTH_TOKEN` instead,
treat it as you would any production credential: organization-level where
possible, rotated on a schedule.

`CI_AUTOFIX_TOKEN` is optional and is used for exactly one thing — pushing, so the
push starts a fresh CI run. Give it the least it can do: `repo` and `workflow`.

Nothing in this repository should ever contain a credential. Account identifiers
belong in `config.sh`, which is gitignored.

## A note on prompt injection

The model reads your CI logs, and CI logs can contain text written by anyone who
can influence a build — a dependency's output, a test fixture, a commit message.
Assume that text is hostile.

The mitigations are the guard and the permission set, not the prompt. The guard
inspects the resulting diff mechanically and does not care what the model was
told. The model has no push permission, cannot rewrite history, and has no access
to secrets or the GitHub API beyond reading runs and pull requests.

## Reporting a vulnerability

Open a [security advisory](../../security/advisories/new) rather than a public
issue. Please include what an attacker would need to control, and what they would
get.
