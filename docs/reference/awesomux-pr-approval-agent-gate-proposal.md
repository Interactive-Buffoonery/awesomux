# awesoMux PR approval agent gate proposal

Status: **superseded by the review-only code-review implementation**. The
maintainer-only `/codereview` workflow may receive provider secrets and update
one informational sticky comment, but it cannot submit a GitHub approval,
write labels, or merge a pull request.

## 2026-07-11 review-only amendment

This amendment supersedes conflicting approval and merge text later in this
historical proposal:

- Standard reviews use exact Kimi K2.7 through Synthetic.
- `review:security` or `review:in-depth` selects the deeper review profile on
  the same exact Synthetic model. There is no automatic provider fallback.
- Provider errors, invalid schemas, stale heads, and uncertainty fail closed
  and require human review; they never silently purchase a provider retry.
- Sensitive classifications constrain approval decisions but do not prevent
  the review-only workflow from producing findings.
- The reviewer has no approval or merge capability. Any future merge automation
  belongs to the independent test-runner system.

This proposal adapts the architecture documented in
[`posthog-pr-approval-agent-research.md`](posthog-pr-approval-agent-research.md)
to awesoMux. It preserves the upstream safety contract while replacing
PostHog-specific policy with thresholds and risk surfaces derived from this
repository.

## Required invariants

The implementation must enforce all of these mechanically:

1. Fail closed on exceptions, invalid policy, incomplete GitHub data, unknown
   mergeability, stale heads, model outages, malformed model output, and
   ambiguous approval history.
2. Deterministic gates are authoritative. The LLM may change an eligible result
   to refusal or escalation; it can never turn a deterministic denial into an
   approval.
3. The only review event the agent may submit is `APPROVE`. Every other result
   is an informational sticky comment. It must never submit
   `REQUEST_CHANGES`.
4. The agent must never push, edit the PR branch, execute PR-controlled code,
   or orchestrate a merge.
5. Workflow, engine, policy, reviewer guidance, ownership, and trusted-agent
   configuration changes must deny their own automatic approval.
6. Every approval must name the exact reviewed head SHA.
7. Any new head SHA dismisses the old agent approval and requires a fresh run.
   V1 has no trivial-delta retention exception.
8. Bot-authored, fork-authored, and non-maintainer-authored PRs are ineligible.

## Evidence used for calibration

GitHub reports 529 merged PRs from 2026-04-30 through 2026-07-11. For
substantive sizing, docs, tests, snapshots, images, string catalogs, and other
non-runtime artifacts were excluded from the numeric ceiling but remained part
of the review evidence.

| Metric | All 529 merged PRs | 195 PRs merged July 4-11 |
| --- | ---: | ---: |
| Substantive lines p50 / p75 / p90 / p95 | 88 / 279 / 688 / 1,029 | 74 / 225 / 661 / 856 |
| Substantive files p50 / p75 / p90 / p95 | 3 / 5 / 11 / 15 | 3 / 6 / 11 / 14 |
| Raw lines p50 / p75 / p90 / p95 | 214 / 545 / 1,291 / 2,061 | 208 / 411 / 1,122 / 1,675 |

The proposed hard ceiling of 700 substantive lines or 15 substantive files is
the rounded all-history p90 line boundary and p95 file boundary. Before path
denials, 473/529 historical PRs and 175/195 last-week PRs fit that envelope.

The proposed path denials would have matched 192/529 historical PRs and 66/195
last-week PRs. The size ceiling would have denied another 24 and 9,
respectively, leaving 313/529 historical PRs and 120/195 last-week PRs eligible
for model review. This is intentionally conservative.

The hard-deny candidates are grounded in repository history and architecture:

| Candidate surface | Historical merged PRs | Last week | Policy |
| --- | ---: | ---: | --- |
| CI and executable automation | 110 | 32 | hard deny |
| Dependencies, toolchain, submodules, vendor pins | 24 | 3 | hard deny |
| Agent install, hook, plugin, and command bridge execution | 36 | 16 | hard deny |
| Persistence and migration paths | 14 | 5 | hard deny |
| Remote/SSH credential and transport paths | 19 | 11 | hard deny |
| Privacy and sanitization paths | 12 | 3 | hard deny |
| Distribution, signing, licensing, and firewall policy | 4 | 4 | hard deny |
| Ghostty/runtime-root paths | 180 | 68 | model scrutiny, not blanket deny |

Ghostty/runtime-root work is common enough that hard-denying it would defeat the
agent's purpose. It instead enters risky-territory review, which requires
independent current-head assurance.

## Proposed workflow and trigger contract

The review-only comment trigger is `/codereview`.

```yaml
ci: GitHub Actions
trusted_branch: main
trigger_label: "agent:approve"
trigger_users:
  - serabi
  - edequalsawesome
events:
  - labeled
  - unlabeled
  - ready_for_review
  - synchronize
  - reopened
  - issue_comment
  - pull_request_review_comment
  - workflow_dispatch
concurrency:
  group: "pr-approval-${PR_NUMBER}"
  cancel_in_progress: true
```

Trigger behavior:

- `labeled`: run only when an allowed user applies `agent:approve`.
- `ready_for_review`, `synchronize`, and `reopened`: run only while the label is
  present.
- `unlabeled`: dismiss any current agent approval and stop; do not call the LLM.
- `workflow_dispatch`: allow Sarah or Ed to retry a labeled PR after an
  infrastructure failure without creating a meaningless commit.
- `issue_comment` and `pull_request_review_comment`: run in review-only mode
  when Sarah or Ed starts a comment with `/codereview`. This mode uses
  the same deterministic evidence collection and Synthetic reviewer, but it
  can never approve or change the approval label.
- Draft PRs may carry the label, but do not run until `ready_for_review`.
- Any new head SHA immediately invalidates the old approval. V1 always reruns;
  it does not attempt to retain approval for docs, tests, or merge commits.

Why explicit opt-in: of the 195 PRs merged July 4-11, 127 had multiple commits,
46 had four or more commits, and only 27 used draft-to-ready. Running on every
open or push would review many intermediate states; ready-for-review alone
would miss most PRs.

## Prerequisite gates

Run these before classification or an LLM call:

1. Repository and base branch are exactly
   `Interactive-Buffoonery/awesomux:main`.
2. Trigger actor is `serabi` or `edequalsawesome`.
3. PR author is `serabi` or `edequalsawesome`, is not a bot, and the head
   repository is the base repository rather than a fork.
4. PR is open, non-draft, and still carries `agent:approve`.
5. GitHub returns a concrete head SHA and merge base.
6. Mergeability is `MERGEABLE`; `UNKNOWN` waits and `CONFLICTING` refuses.
7. No reviewer's latest review state is `CHANGES_REQUESTED`.
8. The evidence bundle, policy, and trusted checkout all identify the same head
   SHA immediately before publishing.

The current `Swift` workflow is manual-only, so V1 does not pretend there is a
required PR build/test check. Check results are model context, not a hard gate.
Adding automatic PR CI is a separate maintainer decision.

## Proposed policy

The eventual machine-readable policy should express this configuration. The
regexes are repository-relative and case-sensitive unless noted otherwise.

```yaml
version: 1

deny:
  self_governance:
    rationale: The approval agent cannot approve changes to its own trust inputs.
    paths:
      - '^tools/pr-approval-agent/'
      - '^\.approval-agent/'
      - '^\.github/workflows/pr-approval-agent\.yml$'
      - '^\.github/CODEOWNERS$'
      - '^AGENTS\.md$'
      - '^CLAUDE\.md$'
      - '^\.deepsec/'
    titles:
      - '(?i)approval agent|auto.?approv|policy|codeowners|agent instructions'

  ci_executable_automation:
    rationale: These files execute with CI, build, or maintainer privileges.
    paths:
      - '^\.github/workflows/'
      - '^\.github/actions/'
      - '^\.github/scripts/'
      - '^script/'
    titles:
      - '(?i)ci|workflow|action|runner|build script|preflight|release|deploy'

  dependencies_toolchain_vendor:
    rationale: These changes select third-party code or alter the build trust chain.
    paths:
      - '^Package\.swift$'
      - '^Package\.resolved$'
      - '^\.gitmodules$'
      - '^vendor/'
      - '^\.github/dependabot\.yml$'
      - '^Resources/Fonts/'
    titles:
      - '(?i)dependenc|toolchain|swiftpm|package|submodule|vendor|ghostty pin|zmx pin'

  distribution_legal_firewall:
    rationale: Signing, release posture, licensing, and the GPL firewall require humans.
    paths:
      - '^LICENSE$'
      - '^SECURITY\.md$'
      - '^THIRD_PARTY_NOTICES\.md$'
      - '^Resources/Licenses/'
      - '(?i)entitlements'
      - '^docs/adr/0019-macos-distribution-signing-and-sandbox-posture\.md$'
    titles:
      - '(?i)sign|notari|hardened runtime|sandbox|license|gpl|distribution|release'

  agent_execution_bridge:
    rationale: These files install or execute agent hooks, plugins, or command bridges.
    paths:
      - '^Resources/AgentIntegrations/'
      - '^Sources/AwesoMuxAgentHook/'
      - '^Sources/AwesoMuxAgentHookSupport/'
      - '^Sources/awesoMux/(Services|Views/GhosttySurface)/.*(AgentHook|AgentIntegration|AgentPlugin|ProcessAgentPluginRunner|CodexHook|CommandBridge)'
      - '^Sources/AwesoMuxCore/Services/CommandBridge'
    titles:
      - '(?i)agent hook|plugin install|command bridge|process runner|execute|shell'

  persistence_migration:
    rationale: Small mistakes here can lose, corrupt, or silently rewrite user state.
    paths:
      - '^Sources/.*/SessionPersistence'
      - '^Sources/.*/.*Migration'
      - '^Sources/.*/.*SnapshotMigration'
    titles:
      - '(?i)migrat|persist|snapshot|restore|data loss|corrupt'

  remote_credentials_transport:
    rationale: Remote and SSH code sits on a credential and command-transport boundary.
    paths:
      - '^Sources/.*(Remote|SSH)'
      - '^docs/adr/0021-remote-markdown-uses-submitted-ssh-target\.md$'
      - '^docs/adr/0022-ssh-credential-custody-and-transport\.md$'
      - '^docs/adr/0023-remote-workspace-architecture\.md$'
    titles:
      - '(?i)remote|ssh|credential|known.?hosts|transport|tunnel'

  privacy_sanitization:
    rationale: These paths govern disclosure, diagnostics, analytics, or hostile text.
    paths:
      - '^Sources/UnicodeHygiene/'
      - '^Sources/.*(ProductAnalytics|PostHog|Feedback|Diagnostic)'
      - '^docs/adr/0008-privacy-boundaries-for-diagnostics-and-feedback\.md$'
      - '^docs/adr/0009-posthog-opt-in-for-macos-error-reporting\.md$'
    titles:
      - '(?i)privacy|analytics|telemetry|diagnostic|feedback|sanitize|unicode|confusable'

allow:
  path_patterns:
    - '^docs/'
    - '^Tests/'
    - '^Resources/Localizable\.xcstrings$'
    - '^\.github/ISSUE_TEMPLATE/'
    - '^\.github/PULL_REQUEST_TEMPLATE'
    - '^README'
    - '^CHANGELOG'
    - '^CONTRIBUTING'
    - '^CODE_OF_CONDUCT'
    - '^SUPPORT'
    - '^GOVERNANCE'
    - '^\.gitignore$'
    - '^\.editorconfig$'
  extensions_only:
    - .png
    - .jpg
    - .jpeg
    - .gif
    - .ico
    - .webp
    - .svg
    - .snap
  test_regex: '^Tests/'
  require_every_path_safe: true

size_gate:
  max_substantive_lines: 700
  max_substantive_files: 15
  excluded_path_prefixes:
    - docs/
    - Tests/
    - generated/
  excluded_extensions:
    - .md
    - .txt
    - .rst
    - .snap
    - .png
    - .jpg
    - .jpeg
    - .gif
    - .ico
    - .webp
    - .svg
    - .pdf
    - .xcstrings
    - .lock
  excluded_name_fragments:
    - /__snapshots__/
  # Runtime-bearing Swift, shell, JSON, YAML, TOML, package, and hook files
  # remain substantive. Exclusion affects only size; deny rules still win.

tiers:
  counts: raw_changed_lines_and_files
  t0:
    description: Every path is allowlisted, or every path is a test.
  t1_subclasses:
    t1a_trivial:
      max_lines: 29
      max_files: 3
      breadth: single-area
    t1b_small:
      max_lines: 99
      max_files: 5
      breadth: not-cross-cutting
    t1c_medium:
      max_lines: 499
      max_files: 15
      breadth: not-cross-cutting
    t1d_complex:
      fallback_within_size_gate: true
  t2:
    description: Any deny category.

breadth:
  ignore:
    - Tests/
    - docs/
  areas:
    - Sources/awesoMux/App/
    - Sources/awesoMux/Services/
    - Sources/awesoMux/Views/
    - Sources/AwesoMuxCore/
    - Sources/AwesoMuxConfig/
    - Sources/AwesoMuxAgentHookSupport/
    - Sources/AwesoMuxAgentHook/
    - Sources/DesignSystem/
    - Sources/UnicodeHygiene/
    - Resources/
  cross_cutting_when:
    - more_than_one_production_target
    - app_services_and_views_and_resources_change_together

ownership:
  source:
    format: github-codeowners
    path: .github/CODEOWNERS
  fallback_reviewers:
    - serabi
    - edequalsawesome
  escalation:
    exclude_pr_author: true
    mention_remaining_reviewers_in_sticky_comment: true
  familiarity:
    strong_min_blame_overlap_pct: 30
    moderate_min_merged_prs: 3
    moderate_max_days_since_touch: 90
    advisory_only: true
    author_ownership_alone_is_not_independent_assurance: true

dismiss:
  retain_on_new_head: false
```

Path matches always hard-deny. Title matches only add trusted scrutiny flags;
they never deny by themselves. A title such as "fix remote label" must be
checked against the actual diff rather than rejected for a keyword.

## Risky-territory model guidance

These common paths do not hard-deny, but the model must require independent
assurance over the risky portion on the current head:

- `Sources/awesoMux/App/AwesoMuxApp.swift`
- `Sources/awesoMux/Services/GhosttyRuntime*`
- `Sources/awesoMux/Views/GhosttySurface/**`
- `Sources/AwesoMuxCore/Stores/SessionStore*` and reducer coordination
- keyboard and command-routing catalogs
- external file, URL, IDE, and custom-command launching
- cross-process locks, process lifecycle, and quit/termination behavior

Independent assurance means one of:

1. a current-head approval or substantive review from the other human owner;
2. a current-head substantive CodeRabbit, Copilot, or OpenCode review with no
   unresolved material concern over that surface.

The PR author's CODEOWNERS status, blame overlap, or prior PR count is context,
not independent assurance. Without independent assurance the model must return
`ESCALATE`.

## Reviewer coordination

```yaml
trusted_humans:
  - serabi
  - edequalsawesome
trusted_reviewer_bots:
  - coderabbitai
  - copilot-pull-request-reviewer
wait_for_fresh_eyes:
  max_minutes: 5
  stale_after_minutes: 45
```

Actions, Linear, and the PR author never count as independent review signals.
Only fresh eyes reactions from the two named reviewer bots are eligible for
the bounded wait.

If polling changes any PR evidence, the entire classification and deterministic
gate sequence reruns before model review.

## Synthetic reviewer and SDK

The approval and review-only modes use the existing Synthetic account and key:

```yaml
provider: synthetic
sdk: openai-agents-python
sdk_version: 0.7.0
api_surface: chat_completions
base_url: https://api.synthetic.new/openai/v1
model:
  requested_id: hf:moonshotai/Kimi-K2.7-Code
  expected_returned_id: moonshotai/Kimi-K2.7-Code
  allow_floating_alias: false
  allow_fallback_model: false
input_modalities:
  - text
  - image
summary_model: null
compression_model: null
secret: SYNTHETIC_API_KEY
parallel_tool_calls: false
tracing: disabled
session_persistence: disabled
tools:
  - read_diff
  - read_file_at_head
  - read_file_at_base
  - grep_tree_at_head
  - glob_tree_at_head
  - read_review_context
image_evidence:
  max_images: 6
  max_source_bytes_per_image: 5242880
  max_decoded_pixels_per_image: 16000000
  max_redirects: 3
  allowed_https_hosts:
    - github.com
    - user-images.githubusercontent.com
    - private-user-images.githubusercontent.com
    - objects.githubusercontent.com
  accepted_formats:
    - image/png
    - image/jpeg
    - image/webp
  reject_animated_images: true
  reject_svg_and_tiff: true
  strip_metadata: true
  reencode_before_model: true
denied_capabilities:
  - shell
  - subprocess
  - network
  - file_write
  - edit
  - web
  - model_selected_handoffs
turn_limits:
  t0: 5
  t1a_trivial: 5
  t1b_small: 20
  t1c_medium: 20
  t1d_complex: 20
reasoning_effort:
  t0: medium
  t1a_trivial: medium
  t1b_small: high
  t1c_medium: high
  t1d_complex: high
max_completion_tokens_per_call:
  t0: 4096
  t1a_trivial: 4096
  t1b_small: 8192
  t1c_medium: 8192
  t1d_complex: 8192
```

The SDK should register only bounded custom functions. Each tool validates
repository-relative paths, rejects symlinks and traversal, caps bytes/results,
and reads git objects without checking out or running the PR tree. No generic
shell or filesystem tool is exposed to the model.

### Screenshot evidence boundary

Kimi K2.7 Code is already multimodal and includes its own vision encoder, so
the reviewer does not receive Qwen or another captioning model. Passing a
screenshot through a second model would add cost and a lossy evidence boundary
that could omit the visual defect that should tighten the verdict.

The trusted evidence collector may attach screenshots from two sources:

- changed image files read directly from the reviewed base/head git objects;
- images explicitly embedded in the PR body or review discussion and hosted on
  an allowlisted GitHub-owned attachment host.

The model retains no network tool. The collector downloads external images
before the model job, follows only a small bounded number of redirects, and
revalidates the scheme and allowlisted host after every redirect. Arbitrary
external URLs, data supplied by PR code, and images discovered through model
instructions are never fetched.

Every image is treated as untrusted evidence, not instructions. The collector
checks the actual decoded format, byte and pixel ceilings, rejects animation,
SVG, TIFF, malformed data, and decompression bombs, strips metadata, re-encodes
to a normalized raster image, hashes the normalized bytes, and embeds them as
base64 image parts in the Kimi request. Images over the count limit are selected
deterministically and the omission is recorded.

Screenshot observations may tighten a verdict but never loosen deterministic
gates or contradict code/review evidence. If a screenshot is required to
evaluate a claimed visual result but is missing, rejected, or unreadable, the
reviewer returns `ESCALATE`; it never assumes the UI is correct. Image hashes,
dimensions, normalized byte counts, source class, and model token usage are
included in the audit artifact without retaining third-party tracking metadata.

V1 pins `hf:moonshotai/Kimi-K2.7-Code` deliberately. It does not use the
floating `syn:large:vision` alias, even while that alias resolves to Kimi K2.7
Code, because an alias could change approval behavior without an engine or
policy change. If Synthetic retires the pinned model or returns 404, the run
fails closed until a maintainer evaluates and explicitly updates the policy.
There is no silent fallback to GLM-5.2 or another model.

The authoritative approval path does not use GLM-4.7-Flash,
`syn:small:text`, or any other small model for review summaries, context
compression, ranking, or evidence selection. A lossy summary could omit the
fact that should make the reviewer refuse. PR text, discussion, review state,
and tool output are sanitized, paginated, and deterministically capped; the
reviewer can retrieve the normalized source material through bounded tools.
Sticky-comment prose is rendered from the validated verdict by deterministic
templates. The separate Linear sidecar may use `syn:small:text` only after the
authoritative verdict is complete, and its prose cannot affect that verdict.

The substantive size gate bounds the primary diff before an LLM call. Tool
results have per-call byte/result caps, and completion limits vary by tier as
shown above. Hitting a turn or completion limit before a valid final schema is
`ERROR`, never approval.

The output is a strict terminal `submit_verdict` function tool with exactly:

```yaml
verdict: APPROVE | REFUSE | ESCALATE
reasoning: bounded string
risk: low | medium | high
issues: bounded list of bounded strings
```

The terminal tool is Pydantic-validated locally. It is the only tool allowed to
end a run; bounded evidence tools continue the run. Plain-text termination,
zero or multiple terminal calls, a terminal call before deterministically
required evidence tools, SDK exceptions, max-turn exhaustion, refusal, missing
fields, extra fields, or invalid enum values map to `ERROR` or `ESCALATE`, never
approval.

This tool-shaped terminal contract replaces the Agents SDK `output_type`
response-format path. Live contract testing on 2026-07-11 found that Synthetic
honored function tools and structured output independently, but Kimi and
GLM-5.2 skipped or malformed tool calls when both were combined in one Chat
Completions request. A strict terminal function preserves the same closed schema
without relying on that incompatible combination.

### Specialist reviewer expansion

V1 starts with one general Kimi reviewer so its quality, failure modes, latency,
and cost can be measured cleanly. The engine is nevertheless structured around
a reviewer registry so maintainers can add specialist agents when evidence
shows they improve review quality. Initial candidates are Swift/macOS runtime,
security and supply chain, CI and testing, and Ghostty integration specialists.

Specialists are separate, independently bounded OpenAI Agents SDK runs using
the same pinned Kimi model, strict output schema, and read-only tool set. The
trusted workflow selects them deterministically from changed paths and gate
evidence; the model cannot create agents, choose specialists, hand off work, or
expand their capabilities. No session state is shared except the normalized,
SHA-bound evidence explicitly supplied by the workflow.

Specialist verdicts are advisory inputs to a deterministic conservative
reducer, never votes. Any runtime or validation error prevents approval; any
`ESCALATE` escalates; any `REFUSE` refuses; and `APPROVE` remains possible only
when every required reviewer is clean and every deterministic gate passes.
Neither a general reviewer nor any number of specialists can loosen a gate.

Adding or materially changing a specialist is a policy change. It requires
contract tests, targeted historical replay, a review-only pilot, measured token
and latency impact, and explicit Sarah-or-Ed sign-off before its output can
participate in real approvals. Specialists should be invoked conditionally
rather than on every PR so additional scrutiny and cost track the relevant
risk.

### Linear maintenance sidecar

A separate, non-authoritative Linear sidecar keeps the linked `INT` issue in
sync with the PR lifecycle and validated review outcome. It is not an approval
reviewer or specialist, does not participate in the verdict reducer, and cannot
block, enable, dismiss, or publish a GitHub approval.

Issue association is deterministic. The controller extracts exactly one
`INT-[0-9]+` identifier from the branch name and trusted GitHub/Linear link
metadata, then verifies that the issue belongs to the Interactive Buffoonery
team and awesoMux project. Missing or conflicting identifiers produce a warning
and no Linear mutation; the small model never chooses an issue.

The sidecar uses the same OpenAI Agents SDK and Synthetic account, but a
separate single-turn agent with no tools:

```yaml
linear_summary_agent:
  provider: synthetic
  api_surface: chat_completions
  model:
    requested_id: syn:small:text
    current_resolved_id: hf:zai-org/GLM-4.7-Flash
    allow_provider_managed_rotation: true
    allow_fallback_model: false
  tools: []
  tracing: disabled
  session_persistence: disabled
  max_turns: 1
  max_completion_tokens: 768
  output_schema:
    summary: bounded string
    next_action: bounded string | null
```

Synthetic currently designates `syn:small:text` as its recommended small text
route and resolves it to GLM-4.7-Flash. Provider-managed rotation is acceptable
for this narration-only sidecar because a model change cannot affect gates or
approval, every run records the resolved model ID, and invalid output falls
back to deterministic prose. This exception does not permit aliases in the
authoritative Kimi review path.

The small model receives only normalized PR metadata, the validated gate/review
outcome, and bounded public findings. It writes concise neutral summary prose;
it never receives repository contents, credentials, raw untrusted instructions,
or a Linear/GitHub tool. Deterministic templates render a usable update if the
model is unavailable or its output is invalid, so Linear narration failures do
not affect the approval workflow.

Repository-owned code performs an allowlisted set of Linear mutations:

- PR opened or marked ready for review: move a linked active issue to `In
  Review` and create or update the sidecar's marker-bearing status comment.
- New reviewed head: update that same comment with the head SHA, gate outcome,
  neutral summary, next action, and GitHub Actions run link.
- Validated `REFUSE`: add `agent:needsResponse` after fetching and preserving
  the issue's complete existing label set.
- Validated `ESCALATE`: add `agent:needsHumanDecision` after fetching and
  preserving the complete label set.
- Validated and published `APPROVE`: update the comment and clear only a stale
  sidecar-owned `agent:needsResponse`; V1 does not automatically apply
  `agent:readyToLand` or reassign the issue because approval is not yet a full
  merge-readiness signal.
- PR merged: move the linked issue to `Done` and remove stale operational
  handoff labels. Merge state is refetched from GitHub rather than inferred
  from model prose.
- PR closed without merge, ambiguous issue linkage, or API error: make no
  lifecycle transition and surface a retryable workflow warning.

The sidecar cannot create or delete issues, edit titles/descriptions, change
priority/project/cycle, reassign ownership, or add arbitrary labels. Its comment
uses a hidden ownership marker plus PR number, head SHA, outcome hash, and
schema version so retries update in place rather than spam Linear. Before every
mutation it refetches the issue and merges label changes to avoid replacing
unrelated labels.

Linear summarization and publication are separate jobs. The summary job receives
`SYNTHETIC_API_KEY` but no Linear or GitHub write credential. The publisher
receives a dedicated `LINEAR_API_KEY` and the validated artifact but no
Synthetic key or GitHub write credential. The Linear identity and credential
must be chosen by Sarah and Ed before implementation; CI must not reuse Sarah's
local CLI token. API rate-limit headers, GraphQL errors, retries, and mutation
results are recorded in a separate audit artifact without storing either
secret.

Synthetic exposes Kimi K2.7 Code through an OpenAI-compatible Chat Completions
API.
The Agents SDK uses an `AsyncOpenAI` client pointed at Synthetic and an
`OpenAIChatCompletionsModel`; no OpenAI credential is involved. The SDK's
explicit tool list, Pydantic terminal verdict tool, turn caps, disabled tracing, and lack
of a session object reproduce PostHog's mechanical Read/Grep/Glob containment.

Provider-side structured output and tool behavior must pass contract tests
before the workflow is enabled. Local schema validation remains authoritative:
unsupported parameters, malformed tool calls, invalid JSON, or schema drift
produce `ERROR` or `ESCALATE`, never approval.

Every evidence bundle records the requested model ID, provider-returned model
ID, reasoning effort, model turns, input tokens, cached-input tokens when
reported, output/reasoning tokens when reported, finish reasons, and aggregate
usage. Synthetic's 2026-07-11 live model catalog pairs the pinned request ID
`hf:moonshotai/Kimi-K2.7-Code` with the returned Hugging Face identity
`moonshotai/Kimi-K2.7-Code`. Both strings are pinned independently; the request
must match the first and every provider response must exactly match the second.
There is no prefix normalization, alias acceptance, or fallback. Any other
provider-returned model ID fails closed. These fields make token appetite and future model comparisons measurable
without changing the approval path.

Kimi K2.7 Code has a 256K context window and is currently priced by Synthetic
at $0.95 per million input tokens and $4.00 per million output tokens for
usage-based metering. The repository's 700-substantive-line gate keeps the
review workload comfortably inside that context. Token and request usage are
still measured rather than assumed because model verbosity and tool behavior
can dominate nominal per-token pricing.

## Model validation and staged rollout

Approval publication is disabled until Kimi K2.7 Code completes all stages
below. A passing deterministic gate is not enough to enable the model to
approve during evaluation.

### Stage 1: provider contract tests

Run live tests against the pinned Synthetic model for:

1. multi-turn function calling with each bounded read-only tool;
2. JSON Schema/Pydantic verdict output for every valid enum value;
3. normalized PNG, JPEG, and WebP image inputs through the exact Agents SDK and
   Synthetic Chat Completions path, both alone and alongside tool calls;
4. malformed, oversized, animated, unsupported, redirecting, and
   decompression-bomb image fixtures being rejected before the model request;
5. screenshot text being treated as untrusted evidence rather than an
   instruction, with missing required visual evidence producing `ESCALATE`;
6. malformed tool arguments, unknown tools, truncated completions, timeouts,
   429s, 5xx responses, and model refusals;
7. provider-returned model identity matching the requested pin;
8. turn and completion limits producing `ERROR`, never approval;
9. no network, shell, write, edit, or environment-reading capability reaching
   the model.

The contract stage requires 100% fail-closed behavior. Any unsupported schema
feature is either simplified without weakening validation or blocks the model
from progressing to review evaluation.

### Stage 2: historical shadow replay

Replay at least 50 recent PR snapshots without posting to GitHub. Stratify the
sample across T0, T1a, T1b, T1c/T1d, risky-territory, and deterministic-deny
cases. Prefer PRs with concrete existing human, CodeRabbit, Copilot, or OpenCode
findings so the evaluation has known signals rather than treating "merged" as
proof that a change was safe.

For each snapshot, preserve the historical head SHA and compare:

- deterministic classification and gate result;
- Kimi verdict, risk, issues, cited paths/lines, and tool evidence;
- unresolved material findings known at that head;
- invalid outputs, retries, turns, latency, and token/quota usage;
- whether the explanation is specific enough for Sarah or Ed to act on.

Historical shadow acceptance requires:

1. zero approvals for deterministic-deny fixtures;
2. zero approvals over an outstanding `CHANGES_REQUESTED` review;
3. zero approvals on curated cases with a known unresolved blocking defect;
4. no invented blocking finding in more than 10% of eligible cases;
5. at least 90% recall on the curated set of known blocking findings;
6. at least 95% valid final schemas without an infrastructure retry;
7. every invalid or incomplete run ending in `ERROR` or `ESCALATE`;
8. a recorded median and p90 cost, token count, turn count, and latency.

The percentages are promotion criteria for the sampled evaluation, not claims
about general model accuracy. Any ambiguous classification is reviewed
manually and retained in the evaluation record.

### Stage 3: live review-only pilot

Enable `/codereview` review-only mode for at least 10 real PRs. Kimi may
publish only its separate sticky review comment; `agent:approve` remains unable
to post an approval. Sarah or Ed rates each review as useful, harmless but
incomplete, or unsafe/misleading and records missed or invented findings.

The pilot passes when:

- no review is rated unsafe/misleading;
- at least 8 of 10 are useful;
- no blocking human or trusted-bot finding was missed and contradicted by a
  clean Kimi verdict;
- schema reliability, latency, and quota consumption remain acceptable in the
  real workflow.

### Stage 4: maintainer go/no-go

Summarize contract, shadow, and live-pilot results in a checked-in evaluation
report with the exact engine version, policy SHA, model ID, sample PRs, known
limitations, and measured usage. Sarah or Ed must explicitly approve enabling
real `APPROVE` reviews. Until that change lands, approval mode returns a
review-only result even when every gate passes.

After activation, retain a rollback switch that disables approval publication
without disabling review-only mode. Review quality and quota usage again after
the first 25 approvals and whenever the model pin, prompt, tools, policy, or
provider behavior changes.

## Disposable macOS test runner

The first self-hosted macOS pilot uses Sarah's `purpleimac`: an Apple Silicon M1
iMac with 16 GB of memory. Runny.app provides the Apple Virtualization boundary
and one-job GitHub Actions runner lifecycle by cloning a clean OCI-backed image,
registering an ephemeral JIT runner, executing one job, deregistering it,
destroying the clone, and starting again from the unchanged image. Runny is
controlled through the private `Interactive-Buffoonery/runner-control`
repository; the public awesoMux repository never registers a persistent runner.

Read-only inventory on 2026-07-11 confirmed an 8-core M1, macOS 26.5.2,
approximately 472 GB free on the 1 TB internal SSD, host Xcode 26.6, and Zig
0.15.2. Runny.app v1.1.0 is installed under the dedicated `github-runner`
account. Host Xcode does not determine the guest toolchain; the pinned image
still carries the repository's selected Xcode.

The pilot deliberately runs one VM at a time. Start with 4 virtual CPUs, 8 GB
of guest memory, and at least a 100 GB virtual disk; measure Ghostty/Xcode peak
memory and build time before changing those values. The host must retain enough
memory for macOS, Runny, and filesystem caching without sustained swap pressure.

Use the pinned Tahoe/Xcode OCI image selected in the Runny setup document. Pin
the OCI manifest digest rather than a movable tag, and keep repository checkouts
and project secrets out of the image. Record the host OS, guest OS, Xcode,
Swift, Zig, Runny, runner, and image digest in every run.

The self-hosted runner does not consume hosted GitHub Actions minutes; expected
local costs are storage, electricity, machine maintenance, and any separately
chosen paid support or hosted service. Review the applicable Apple macOS and
Xcode license terms before production use; the guest must remain on
Apple-branded hardware.

### Control plane and trust boundary

Do not register a persistent bare-metal runner directly to the public awesoMux
repository. The pilot uses a private runner-control repository or equivalently
restricted private runner group that only Sarah and Ed can dispatch. A hosted
control job validates the actor and a full commit SHA, verifies that SHA belongs
to the intended awesoMux PR or trusted branch, and only then queues the isolated
VM job.

The VM job receives `contents: read`, an ephemeral read-only GitHub token, and
no Synthetic, Linear, signing, notarization, SSH, personal GitHub, or GitHub
write credential. It checks out the exact validated SHA and recursively fetches
the pinned Ghostty and zmx submodules. The host account contains no project
checkout or model/publishing secret. Its only CI credential is the narrowly
scoped runner-registration identity stored in the host keychain and made
unavailable to guests. PR code never executes directly on the host.

Before outside-contributor PRs may run automatically, demonstrate that a guest
cannot reach the host control API, host filesystem, host SSH agent, personal
LAN services, or credentials; constrain guest egress to the endpoints needed
for GitHub and declared dependencies; forward Runny and runner lifecycle logs
outside the destroyed VM; and test cleanup after timeout, cancellation, panic,
host reboot, and network loss. A destroyed clone is not evidence of isolation
unless those boundaries are tested.

### Test command and staged promotion

The trusted controller chooses the validation entry points rather than
accepting an arbitrary workflow command from the PR:

1. agent-hook tests;
2. zmx tests and `script/build_amx.sh`;
3. `script/build_ghostty_xcframework.sh`;
4. `script/swift-test.sh`;
5. `script/preflight.sh` once the earlier stages are stable in the VM.

Every checked-out script, package manifest, test, compiler plugin, and build
input remains untrusted PR code and may execute arbitrary commands inside the
guest. The fixed entry-point list reduces accidental drift but is not a sandbox;
the disposable VM and network boundary remain mandatory.

During the pilot the result is informational and cannot affect approval. Run at
least 20 representative exact-SHA jobs, including success, test failure,
timeout, cancellation, runner restart, and deliberately dirty-workspace cases.
Promotion requires correct SHA attribution on every run, zero cross-job state
survival, no secret exposure, at most one infrastructure failure, acceptable
queue/build latency, and explicit Sarah-or-Ed sign-off.

After promotion, publish a commit-bound `awesomux-macos` check through a
separate hosted publisher that receives the validated test artifact but no VM
or model credentials. A missing, stale, cancelled, or failing required check
produces `WAIT` or `ERROR`, never approval; Kimi and its specialists cannot
override it. If `purpleimac` is offline, approval waits rather than silently
falling back to an unapproved runner. Ed's Macs may later join the same pool
only after independently passing the host and golden-image qualification.
The publisher derives pass/fail from GitHub's job conclusion and independently
matches the controller-approved SHA; it never trusts a pass flag or SHA written
by checked-out PR code.

## Credentials and GitHub permissions

Credential route:

```yaml
model_secret: SYNTHETIC_API_KEY
linear_secret: LINEAR_API_KEY
github_identity: github-actions[bot]
analysis_job_permissions:
  contents: read
  pull-requests: read
publish_job_permissions:
  contents: read
  pull-requests: write
  issues: write
linear_summary_job_permissions:
  contents: read
  pull-requests: read
linear_publish_job_permissions:
  contents: read
  pull-requests: read
macos_vm_job_permissions:
  contents: read
macos_check_publish_job_permissions:
  contents: read
  checks: write
```

Reuse the existing `SYNTHETIC_API_KEY` currently dedicated to OpenCode review.
Expose it only to read-only model jobs: the approval analysis job and Linear
summary job. The GitHub and Linear publishing jobs receive validated artifacts
but not the Synthetic key. Only the Linear publisher receives
`LINEAR_API_KEY`; it receives no GitHub write token. The model never receives an
environment-reading tool.

The repository setting already permits GitHub Actions to create PR approvals,
so no GitHub App is required. The publishing code may create/dismiss only its
own marker-bearing approval and sticky comment. No job receives `contents:
write`, `actions: write`, or administration permissions.

No OpenAI API key, personal Codex credential, `auth.json`, or Codex access token
is required.

## OpenCode replacement

The new engine replaces the repository's OpenCode CI integration rather than
running beside it:

1. Remove the automatic `opencode-review` workflow.
2. Remove the synchronize reminder workflow.
3. Replace the existing `/oc` and `/opencode` workflow with `/codereview`
   review-only mode in the approval-agent engine.
4. Remove the trusted `run-opencode` composite action and CI-only parsing,
   guard, inline-publishing, reminder, and trust-boundary helpers/tests that no
   longer have a caller.
5. Retain `.opencode/` as local developer configuration; it is no longer a
   trusted input to CI or the approval agent.

V1 has one bounded Synthetic reviewer session per invocation. After specialist
expansion, an invocation may have multiple independently bounded sessions
selected by deterministic policy; each may make multiple model turns while
using read-only tools. Automatic PR-open reviews stop. A maintainer either
applies `agent:approve` for a gate-plus-review run or uses `/codereview` for an
earlier review-only run.

Approval mode publishes `APPROVE` only after every gate and reviewer condition
passes. Review-only mode never approves, dismisses approvals, or changes the
trigger label; it updates a separate marker-bearing sticky review comment.
Neither mode submits `REQUEST_CHANGES` or merges. Findings are rendered with
path and line links in the sticky comment rather than as a `COMMENT` review, so
the approval architecture's review-event invariant remains intact.

## Verdict and label lifecycle

| Result | GitHub action | Label |
| --- | --- | --- |
| `APPROVED` | Commit-bound `APPROVE` review | keep |
| `REFUSED` | Update sticky informational comment | remove |
| `ESCALATE` | Update sticky comment and mention other owner | remove |
| `WAIT` | Update sticky comment; no review | keep |
| `ERROR` | Update sticky comment; no review | keep |
| Crash/no evidence | No approval; update failure note if possible | keep |

Review-only `/codereview` results use a separate sticky comment and never alter
this table's approval or label state.

The sticky comment is updated in place and carries a hidden ownership marker,
engine version, policy SHA, reviewed head SHA, gate summary, and run link. The
workflow uploads a JSON evidence bundle for 30 days.

The agent excludes its own prior marker-bearing reviews/comments from model
evidence. Approval publication performs one last head-SHA and label check in a
separate write-capable job. A mismatch exits without approval.

## Approved implementation decisions

1. Trigger label: `agent:approve`, restricted to Sarah and Ed.
2. Hard deny patterns and risky-territory list above.
3. Hard size ceiling: 700 substantive lines or 15 substantive files.
4. Raw T1 boundaries: 29/3, 99/5, 499/15, then complex.
5. Every new head dismisses and reruns; no trivial-delta retention in V1.
6. Escalation mentions the other owner through CODEOWNERS/fallback.
7. OpenAI Agents SDK with Synthetic's pinned
   `hf:moonshotai/Kimi-K2.7-Code` and custom read-only tools.
8. Reuse the existing `SYNTHETIC_API_KEY`; do not add OpenAI credentials.
9. Replace all OpenCode CI runs; use `/codereview` as the review-only
   entry point backed by the same engine.
10. V1 initially treats Swift CI as informational while the one-VM Runny
    pilot on `purpleimac` is qualified. After the staged reliability and
    isolation criteria pass, require the exact-SHA `awesomux-macos` check as a
    deterministic gate.
11. Do not use floating model aliases, fallback models, or a small model inside
    the authoritative approval path; capture exact model and token usage
    instead. The non-authoritative Linear narrator may use `syn:small:text` and
    must record its provider-resolved model ID.
12. Keep approval publication disabled through provider contract tests, a
    50-PR historical shadow replay, and a 10-PR live review-only pilot; enable
    approvals only after an explicit maintainer review of the results.
13. Start with one general reviewer, but use a reviewer-registry architecture
    that can add deterministically selected, independently bounded specialists;
    combine their verdicts conservatively, with no voting or model-selected
    handoffs, and stage each specialist through evaluation and sign-off.
14. Add a credential-isolated Linear maintenance sidecar. Deterministic code
    owns issue linkage and allowlisted mutations; `syn:small:text` supplies only
    optional neutral prose, with deterministic fallback, no tools, and no
    influence over approval.
15. Send bounded, normalized screenshot evidence directly to multimodal Kimi;
    do not add Qwen or a captioning intermediary. Keep all fetching and image
    validation in trusted deterministic code, and let visual evidence only
    tighten the verdict.
16. Use Runny for one disposable macOS VM runner at a time on the 16 GB M1
    `purpleimac`, controlled through the private `runner-control` trust boundary
    with no project secrets. Qualify it through 20 exact-SHA pilot jobs before
    allowing its result to gate approval; Ed's Macs may join only after the same
    checks.
