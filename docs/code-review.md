# OpenCode PR reviews

awesoMux keeps AI review and deterministic testing separate:

- **OpenCode review** performs read-only PR review with exact Kimi K3 through
  Synthetic.
- **Native validation** runs existing test and staging scripts for an immutable
  pull-request SHA when an allowlisted maintainer requests `/ci`. It is advisory
  and does not produce code-review findings.

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

Automatic review skips pull requests above 2,000 changed lines and updates one
marked pull-request comment with the reason. An allowlisted maintainer can use
the same exact `/codereview` command to deliberately request a larger bounded
review; requested reviews accept up to 10,000 diff lines or 512 KiB.

## Trust boundary

The workflows check out the repository's trusted default branch, then fetch the
pull request head as passive Git data. They do not check out or execute PR-head
code, install its dependencies, or load its OpenCode project configuration.

The local action, helper scripts, `.opencode` configuration, review agent, and
review skill all come from the trusted default branch. Trusted code validates
the exact 40-character base and head SHAs. Each workflow passes those trusted
event or API values directly to the review and publication steps instead of
round-tripping the range through filename-bearing workflow outputs. Guard code
derives changed paths as NUL-delimited data from the same range. Trusted code
then produces one diff with external diff drivers and text conversion disabled
and enforces the review's line and byte limits before starting OpenCode.
Pull-request title and body metadata are encoded into a separate UTF-8-safe file
capped at 64 KiB.

The trusted runner combines its instructions, review policy, bounded metadata,
and exact diff into one immutable packet. It pipes that packet to OpenCode over
standard input so the 256 KiB automatic and 512 KiB requested-review byte limits
do not depend on shell argument or environment limits. The review agent has no
tools. CI resolves the effective pinned OpenCode agent configuration before each
run and fails if any tool remains enabled or the effective permission policy is
not deny-by-default.

OpenCode runs from an empty working directory with isolated home and XDG data
directories. Its child environment is cleared and rebuilt with only the model
provider key and required runtime/configuration values. The GitHub publication
token stays in the trusted parent process, which validates the final
`## Code Review` response before updating the pull-request comment. The workflow
reuses the same boundary for automatic and comment-triggered reviews.

Automatic reviews are limited to same-repository maintainer PRs. Manual
`/codereview` is limited to a login in `MAINTAINER_LOGINS_JSON`, but may inspect
a fork because the fork head remains passive data.

## Model and installation

Both automatic and requested reviews use:

```text
synthetic/hf:moonshotai/Kimi-K3
```

There is no model fallback. The Synthetic key is supplied only to the trusted
review step. Automatic and requested review jobs have a 20-minute timeout so
Kimi K3 can inspect the bounded packet and complete output recovery.
The review agent may take at most 40 steps within that window.
CI asks the pinned OpenCode binary to resolve the trusted review-agent
configuration and fails before review if that effective step limit is not 40.

The review instructions require findings to be checked against the final code,
including callers and other consumers present in the packet when shared
behavior changes. Generated, vendored, lock, snapshot, and mechanically
produced files are excluded from direct review, and every blocker or should-fix
item must name a concrete consequence. If the packet lacks evidence needed to
substantiate a concern, the model omits the finding instead of reading beyond
the bounded input.

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

Usage, quota, billing, provider, setup, or output-contract failures fail the
Actions job. Every failed automatic or requested review also posts or updates
one marked pull-request comment with a sanitized reason and the Actions run
link. Recognized provider errors preserve their specific message while
redacting workspace links and identifiers. A failed review must never be
interpreted as a clean review.

An oversized automatic-review diff is not a review failure. The workflow exits
successfully without invoking the model and posts or updates a marked comment
that explains how to request the larger manual review.

## Required repository configuration

| Name                     | Kind             | Purpose                                                       |
| ------------------------ | ---------------- | ------------------------------------------------------------- |
| `SYNTHETIC_API_KEY`      | Actions secret   | Calls Kimi K3 through Synthetic.                              |
| `MAINTAINER_LOGINS_JSON` | Actions variable | JSON array of logins allowed to trigger review and native CI. |

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
maintainer authorization, exact command matching, immutable stdin packets above
the operating system's single-argument limit, Unicode-safe metadata bounds,
tool/config isolation, model-child environment canaries, inert malicious
Git-shaped input, delimiter-shaped filenames, direct trusted-SHA binding,
trusted publication, installer digest verification, output guards, and
permission-actor forwarding.

## Deterministic validation

Maintainers run `./script/preflight.sh` as the strongest local gate and may
request advisory, exact-SHA hosted native validation with `/ci`. See
[`ci.md`](ci.md) for scopes, authorization, artifacts, and the separation
between required checks, native execution, and review automation.
