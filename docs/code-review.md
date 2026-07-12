# OpenCode PR reviews

awesoMux keeps AI review and deterministic testing separate:

- **OpenCode review** performs read-only PR review with exact GLM 5.2 through
  Synthetic.
- **Swift CI** runs deterministic native builds and tests on standard
  GitHub-hosted macOS infrastructure. It does not produce code-review findings.

Neither system can approve or merge a pull request.

## Review triggers

Automatic review runs when a non-draft, same-repository pull request authored
by a login in `MAINTAINER_LOGINS_JSON` is opened, reopened, or marked ready for
review.

An allowlisted maintainer can request another review, including deliberate
review of a fork PR, by commenting exactly:

```text
/codereview
```

New commits receive a lightweight reminder instead of automatically consuming
another model review.

## Trust boundary

The workflows check out the repository's trusted default branch, then fetch the
pull request head as passive Git data. They do not check out or execute PR-head
code, install its dependencies, or load its OpenCode project configuration.

The local action, helper scripts, `.opencode` configuration, review agent, and
review skill all come from the trusted default branch. The review receives an
exact base/head range and is instructed to inspect that immutable range. The
workflow reuses the same boundary for automatic and comment-triggered reviews.

Automatic reviews are limited to same-repository maintainer PRs. Manual
`/codereview` is limited to a login in `MAINTAINER_LOGINS_JSON`, but may inspect
a fork because the fork head remains passive data.

## Model and installation

Both automatic and requested reviews use:

```text
synthetic/hf:zai-org/GLM-5.2
```

There is no model fallback. The Synthetic key is supplied only to the trusted
review step.

OpenCode is pinned to version `1.17.8`. CI downloads the versioned Linux x64
release archive, verifies its checked-in SHA-256, and only then extracts the
binary. The workflow never executes the upstream `curl | bash` installer.

## Output and failures

The trusted review instructions live in:

- `.opencode/agents/review.md`
- `.opencode/skills/pr-review/SKILL.md`

Public output begins with `## Code Review`, stays concise, and contains only
actionable findings. A guard retries an incomplete narration-only response and
fails after three attempts rather than accepting an empty review.

Usage, quota, billing, provider, or output-contract failures fail the Actions
job. Where possible, the workflow also posts a visible availability comment.
A failed review must never be interpreted as a clean review.

## Required repository configuration

| Name | Kind | Purpose |
| --- | --- | --- |
| `SYNTHETIC_API_KEY` | Actions secret | Calls GLM 5.2 through Synthetic. |
| `MAINTAINER_LOGINS_JSON` | Actions variable | JSON array of logins allowed to trigger paid review. |

## Local verification

Run the review automation tests with:

```sh
./script/test-review-automation.sh
```

Before opening a non-documentation PR, run the full repository gate:

```sh
./script/preflight.sh
```

The review test suite covers trusted-default-branch execution, passive PR data,
maintainer authorization, exact command matching, model/config isolation,
installer digest verification, output guards, and permission-actor forwarding.

## Deterministic CI

The `Swift` workflow builds AMX and Ghostty, then builds and tests awesoMux on a
standard GitHub-hosted `macos-26` runner for non-documentation pull requests and
pushes to `main`. The workflow has read-only repository permissions and receives
no OpenCode or publishing credential. Cheap review-automation, source-policy,
plural, and contrast guards remain separate Linux jobs so they fail quickly.
