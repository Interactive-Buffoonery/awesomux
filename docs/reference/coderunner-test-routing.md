# CodeRunner automatic test routing

CodeRunner is the exact-SHA test runner. The OpenCode reviewer and `/codereview`
are a separate review system; neither system controls the other's decision.

## What CodeRunner does today

CodeRunner v1 has two distinct jobs:

1. It **executes a small qualified automatic suite** on a disposable macOS
   guest: repository guards for every eligible PR, plus focused agent-hook
   tests when agent-hook paths change.
2. It **reports the heavier validation that still needs a maintainer**. Swift,
   AMX, Ghostty, app verification, and preflight commands are selected from the
   changed paths, deduplicated, and shown in the plan and result comments.

A successful `CodeRunner` status means only that the selected automatic checks
passed for the exact reported SHA. It does not mean the listed local commands
ran or passed. Checklist state is a coordination aid, not machine attestation;
even a checked box does not change what CodeRunner verified.

The current value is immediate cheap safety coverage, consistent local-test
guidance, and trusted execution infrastructure that can host heavier fixed
capabilities after their runner image and runtime have been qualified.

## Eligibility and triggers

Automatic planning runs only when all of these are true:

- the pull request author is `serabi` or `edequalsawesome`;
- the head and base repositories are `Interactive-Buffoonery/awesomux`;
- the base branch is `main`;
- the pull request is open and out of draft; and
- the event is `opened`, `reopened`, `synchronize`, or `ready_for_review`.

Sarah or Ed can explicitly request a fresh run by adding or re-adding the base
`CodeRunner` label. Pull requests from other authors do not run automatically;
Sarah or Ed test those locally first.

For an existing eligible PR, add the label in GitHub's PR sidebar. If the label
is already present, remove and re-add it. A later push to the PR triggers another
run automatically through the `synchronize` event.

## Automatic plan

Trusted code on the source workflow and trusted code in the private controller
independently classify the exact changed-file list. The private controller runs
the union, so disagreement can add coverage but cannot remove a required check.

| Changed area | Runny automation | Sarah/Ed local validation |
| --- | --- | --- |
| Documentation and static assets only | repository guards | none |
| Core, config, secure I/O, Unicode, or DesignSystem Swift | repository guards | `./script/swift-test.sh` |
| App, view, service, resources, localization, or app tests | repository guards | Swift tests and `build_and_run.sh --verify` |
| Agent-hook shell transport | repository guards and agent-hook tests | none |
| Agent-hook Swift support | repository guards and agent-hook tests | Swift tests |
| AMX or zmx | repository guards | zmx tests, AMX build, Swift tests, and app verification |
| Ghostty integration | repository guards | Ghostty build, Swift tests, and app verification |
| Package, CI, build, preflight, release, or signing infrastructure | repository guards | preflight |
| More than 700 substantive lines or 15 substantive files | repository guards | preflight plus any component-specific commands |

`CodeRunner` is the only label. It requests a fresh run; it does not choose or
skip checks.

## What to inspect on a run

Each run has four operator-visible artifacts:

1. The public **CodeRunner planning** workflow validates eligibility, posts the
   exact-SHA plan, and dispatches the private controller.
2. The private controller validates the PR and changed-file list independently,
   transfers a credential-free source bundle, and runs the fixed capability set
   on a fresh Runny guest.
3. The **CodeRunner result** workflow runs as `coderunner-reporter[bot]` and
   posts per-check and total durations.
4. The PR head receives a SHA-bound `CodeRunner` commit status linked to the
   private controller run.

The result comment should repeat every required local command under **Still
required locally** and explicitly state that CodeRunner does not attest to its
result. If the PR head moves, authentication is wrong, metadata is incomplete,
or a hosted/guest step cannot be verified, the run fails closed instead of
publishing success.

## PR messages and status

Before dispatch, the trusted source workflow posts an exact-SHA test plan with
the selected capabilities, deterministic reasons, and a conservative duration
estimate. It creates a pending `CodeRunner` commit status for that SHA.

The disposable iMac guest receives the credential-free source bundle and an
Actions-read token. It runs repository guards and, when selected, agent-hook
tests. The
guest receives no comment, status, reporter, model, Linear, signing, SSH, or
merge credential.

The hosted controller derives the result and duration of each automatic check from
GitHub job metadata, revalidates the current PR head and required capabilities,
and dispatches a bounded result through the Actions-only CodeRunner Reporter App.
The source result workflow posts a SHA-bound result table, repeats any required
local commands without claiming they passed, and marks the automated status
successful or failed.

CodeRunner never requests changes, enables auto-merge, or calls a merge API. A
maintainer may use GitHub's native **Enable auto-merge** control only after
completing the listed local commands. GitHub branch protection can wait for the
`CodeRunner` status, but it cannot infer that local checklist items passed.

## Future heavier automation

The source planner, private controller, disposable guest, evidence pipeline,
and Reporter are intentionally capability-based. This is the groundwork for
moving more validation into CodeRunner without changing its trust boundary.

Heavier execution is not enabled merely by adding a command. Before Swift,
AMX, Ghostty, app verification, or preflight can become automatic, the Runny
image must contain and qualify the required toolchain and artifacts (including
Zig/Ghostty where applicable), cold and warm runtimes must be measured, and
both trusted classifiers must add the same fixed capability. Guest commands
remain controller-owned; PR code cannot provide or loosen them. Zig-enabled VM
automation is tracked separately under INT-806.

## Deployed configuration

CodeRunner uses four separate, narrowly scoped GitHub Apps:

- **CodeRunner Runner** owns disposable runner registration for the private
  controller repository.
- **CodeRunner Source Reader** reads the allowlisted source repository only from
  hosted controller jobs.
- **CodeRunner Dispatcher** can dispatch the private controller workflow but
  cannot comment, publish statuses, or read source.
- **CodeRunner Reporter** can dispatch the trusted public result workflow but
  never enters the disposable guest.

Their credentials remain split between the public source and private controller
repositories. No guest job receives an App private key or installation token.

The renamed Dispatcher and Reporter Apps completed qualified end-to-end
canaries on PRs #565 and #569. Requiring the `CodeRunner` status on `main` is a
separate branch-protection decision; it would require only the current
automatic checks and would not attest to maintainer-local validation.

## Troubleshooting

- **No run starts:** confirm the PR is eligible, open, out of draft, based on
  `main`, and authored from the same repository by Sarah or Ed. For a manual
  refresh, remove and re-add `CodeRunner` as Sarah or Ed.
- **A plan appears but no controller run starts:** open the linked public source
  workflow. Dispatch and publication errors fail before guest execution.
- **The controller rejects the request:** confirm the PR head did not change and
  the dispatch actor is `coderunner-dispatcher[bot]`.
- **The automatic status passes while local commands remain:** this is expected.
  Run those commands locally and record their result separately before merge.
- **A new push arrives during a run:** results remain bound to the old SHA and
  cannot attest to the new head; the `synchronize` event starts a fresh plan.
