# PostHog PR approval agent architecture

Research note (not an ADR). This records the reusable architecture and safety
contract of PostHog's PR approval agent, "Stamphog," before adapting it to
awesoMux. It deliberately does not copy PostHog's deny patterns or thresholds:
the upstream authors calibrated those against PostHog's own PR history and say
that size alone is not a safe proxy for risk.

Sources were verified against PostHog commit
[`f2218147`](https://github.com/PostHog/posthog/tree/f2218147c5f0cb6dcf6684e2d24dd0c4d63ed28b)
on 2026-07-11. All citations below are pinned to that commit.

## Executive summary

The architecture is a monotonic approval pipeline:

```text
label/event
  -> trusted-base workflow + PR metadata/diff fetch
  -> deterministic classification and hard gates
  -> wait for in-flight reviewer bots
  -> read-only LLM review
  -> final-verdict combiner
  -> APPROVE review, or one sticky informational comment
  -> preserve/dismiss that approval safely after later pushes
```

Its defining property is not simply "an LLM reviews a PR." It is that every
layer can remove approval eligibility, while no less-trusted layer can restore
it. Deterministic denial outranks the model; model failure produces no
approval; an invalid model verdict escalates; and ambiguous post-approval
history dismisses the stale approval and re-runs review. The README describes
the pipeline and explicitly states that deterministic gates are authoritative
and the LLM may tighten but never loosen them.
([README](https://github.com/PostHog/posthog/blob/f2218147c5f0cb6dcf6684e2d24dd0c4d63ed28b/tools/pr-approval-agent/README.md#L48-L145),
[`review_pr.py`](https://github.com/PostHog/posthog/blob/f2218147c5f0cb6dcf6684e2d24dd0c4d63ed28b/tools/pr-approval-agent/review_pr.py#L717-L739))

## Safety invariants to preserve exactly

1. **Fail closed.** No exception, missing verdict, backend outage, invalid
   policy, ambiguous git history, or stale approval may result in approval.
   LLM errors become `ERROR`; invalid verdicts become `ESCALATE`; malformed
   global policy aborts loading; and post-approval ambiguity becomes
   dismiss-and-review.
   ([`reviewer.py`](https://github.com/PostHog/posthog/blob/f2218147c5f0cb6dcf6684e2d24dd0c4d63ed28b/tools/pr-approval-agent/reviewer.py#L148-L169),
   [`policy.py`](https://github.com/PostHog/posthog/blob/f2218147c5f0cb6dcf6684e2d24dd0c4d63ed28b/tools/pr-approval-agent/policy.py#L1-L20),
   [`dismiss_check.py`](https://github.com/PostHog/posthog/blob/f2218147c5f0cb6dcf6684e2d24dd0c4d63ed28b/tools/pr-approval-agent/dismiss_check.py#L9-L26))
2. **Deterministic gates are authoritative.** A gate denial fixes the final
   result at `REFUSED`, even if the reviewer says `APPROVE` or is unavailable.
   The LLM may change a deterministic T0 approval to escalation, but it cannot
   reverse a denial.
   ([`review_pr.py`](https://github.com/PostHog/posthog/blob/f2218147c5f0cb6dcf6684e2d24dd0c4d63ed28b/tools/pr-approval-agent/review_pr.py#L717-L739))
3. **Never request changes.** The only GitHub review event the workflow posts
   is `APPROVE`. Every non-approval is an issue comment, maintained as one
   sticky comment. The upstream README calls this out explicitly.
   ([README](https://github.com/PostHog/posthog/blob/f2218147c5f0cb6dcf6684e2d24dd0c4d63ed28b/tools/pr-approval-agent/README.md#L136-L145),
   [workflow](https://github.com/PostHog/posthog/blob/f2218147c5f0cb6dcf6684e2d24dd0c4d63ed28b/.github/workflows/pr-approval-agent.yml#L109-L242))
4. **Never merge.** The workflow can post or dismiss its own reviews, comment,
   and remove its trigger label; it has no merge step. Its declared repository
   permissions are only `contents: read` and `pull-requests: write`.
   ([workflow](https://github.com/PostHog/posthog/blob/f2218147c5f0cb6dcf6684e2d24dd0c4d63ed28b/.github/workflows/pr-approval-agent.yml#L1-L13))
5. **Run trusted code, inspect untrusted code.** CI always checks out the base
   repository's hard-coded trusted branch and runs the agent/policy from there.
   It fetches the PR head only as git objects, then computes `base...head`; it
   does not check out or execute PR-controlled workflow or reviewer code.
   ([workflow](https://github.com/PostHog/posthog/blob/f2218147c5f0cb6dcf6684e2d24dd0c4d63ed28b/.github/workflows/pr-approval-agent.yml#L44-L88),
   [`github.py`](https://github.com/PostHog/posthog/blob/f2218147c5f0cb6dcf6684e2d24dd0c4d63ed28b/tools/pr-approval-agent/github.py#L406-L461))
6. **Bind approval to the reviewed commit.** The posting step passes the exact
   reviewed head SHA as `commit_id`; a push during the model round-trip cannot
   transfer the verdict to the new head.
   ([workflow](https://github.com/PostHog/posthog/blob/f2218147c5f0cb6dcf6684e2d24dd0c4d63ed28b/.github/workflows/pr-approval-agent.yml#L109-L142))
7. **Do not let stale bot approval survive meaningful new code.** On
   `synchronize`, a separate delta classifier either retains approval only for
   narrowly defined trivial/clean-base-merge commits or dismisses and re-runs.
   Non-linear history, fetch errors, classifier failure, and a skipped
   classifier all take the dismiss path.
   ([`dismiss_check.py`](https://github.com/PostHog/posthog/blob/f2218147c5f0cb6dcf6684e2d24dd0c4d63ed28b/tools/pr-approval-agent/dismiss_check.py#L63-L104),
   [workflow](https://github.com/PostHog/posthog/blob/f2218147c5f0cb6dcf6684e2d24dd0c4d63ed28b/.github/workflows/pr-approval-agent.yml#L253-L389))
8. **The gate cannot approve changes to itself.** Policy validation requires a
   self-governance deny category covering the policy directory, folder
   overrides, and engine. The deny policy also includes ownership inputs.
   ([`policy.py`](https://github.com/PostHog/posthog/blob/f2218147c5f0cb6dcf6684e2d24dd0c4d63ed28b/tools/pr-approval-agent/policy.py#L226-L298),
   [`policy.yml`](https://github.com/PostHog/posthog/blob/f2218147c5f0cb6dcf6684e2d24dd0c4d63ed28b/.stamphog/policy.yml#L118-L131))
9. **Bot-authored PRs never qualify.** The workflow skips review and removes
   the label for bot authors, while the Python orchestrator independently
   refuses them for local/out-of-band execution.
   ([workflow](https://github.com/PostHog/posthog/blob/f2218147c5f0cb6dcf6684e2d24dd0c4d63ed28b/.github/workflows/pr-approval-agent.yml#L391-L438),
   [`review_pr.py`](https://github.com/PostHog/posthog/blob/f2218147c5f0cb6dcf6684e2d24dd0c4d63ed28b/tools/pr-approval-agent/review_pr.py#L246-L265))

## Execution flow

### 1. Trigger and trusted checkout

The GitHub Actions workflow listens to `pull_request` events `labeled`,
`ready_for_review`, and `synchronize`. A non-draft PR runs when the `stamphog`
label is newly applied, when a labeled draft becomes ready, or when the delta
job requests re-review after a push. Per-PR concurrency cancels an older run.
([workflow](https://github.com/PostHog/posthog/blob/f2218147c5f0cb6dcf6684e2d24dd0c4d63ed28b/.github/workflows/pr-approval-agent.yml#L1-L42))

The job creates a GitHub App token, checks out the trusted `master` ref with
full history and blobless filtering, fetches the PR head ref, installs a pinned
`uv`, and runs the trusted `review_pr.py`. The workflow has a 20-minute cap.
([workflow](https://github.com/PostHog/posthog/blob/f2218147c5f0cb6dcf6684e2d24dd0c4d63ed28b/.github/workflows/pr-approval-agent.yml#L39-L88))

### 2. Fetch and normalize evidence

`github.py` obtains PR metadata, reviews, comments, reactions, and check runs
through `gh`; local git supplies name/status, binary status, additions,
deletions, and the full three-dot diff. Only trusted organization members and
bots are admitted as prompt review/comment sources, Stamphog's own prior
reviews are excluded, and reviewer-bot reactions are allowlisted rather than
trusting every installed app.
([`github.py`](https://github.com/PostHog/posthog/blob/f2218147c5f0cb6dcf6684e2d24dd0c4d63ed28b/tools/pr-approval-agent/github.py#L1-L125),
[`github.py`](https://github.com/PostHog/posthog/blob/f2218147c5f0cb6dcf6684e2d24dd0c4d63ed28b/tools/pr-approval-agent/github.py#L406-L526))

### 3. Classify, resolve policy, and run hard gates

The orchestrator derives path categories, breadth, conventional-commit type,
deny matches, title-only scrutiny flags, dependency state, ownership, T0/T1/T2
tier, T1 sub-tier, and effective folder policy. It then runs exactly these hard
gates in order:

1. prerequisites;
2. deny-list;
3. substantive size ceiling;
4. tier eligibility.

([`review_pr.py`](https://github.com/PostHog/posthog/blob/f2218147c5f0cb6dcf6684e2d24dd0c4d63ed28b/tools/pr-approval-agent/review_pr.py#L354-L442),
[`review_pr.py`](https://github.com/PostHog/posthog/blob/f2218147c5f0cb6dcf6684e2d24dd0c4d63ed28b/tools/pr-approval-agent/review_pr.py#L512-L640))

Prerequisites reject drafts, merge conflicts, and any reviewer's latest
`CHANGES_REQUESTED` state. CI failure is intentionally not duplicated as a
hard gate because CI is expected to be a separate required check and the agent
often starts before checks finish.
([`review_pr.py`](https://github.com/PostHog/posthog/blob/f2218147c5f0cb6dcf6684e2d24dd0c4d63ed28b/tools/pr-approval-agent/review_pr.py#L532-L552))

### 4. Coordinate with other reviewers

Unless gates already deny, the orchestrator polls for fresh eyes reactions
from allowlisted reviewer bots for up to five minutes. If they remain, it
returns `WAIT` and preserves the label for a later retry. Stale bot eyes older
than about 45 minutes are ignored; human eyes are passed to the LLM and block
approval there. If polling refetches PR state, classification and gates are
recomputed before model review.
([README](https://github.com/PostHog/posthog/blob/f2218147c5f0cb6dcf6684e2d24dd0c4d63ed28b/tools/pr-approval-agent/README.md#L88-L101),
[`review_pr.py`](https://github.com/PostHog/posthog/blob/f2218147c5f0cb6dcf6684e2d24dd0c4d63ed28b/tools/pr-approval-agent/review_pr.py#L130-L145))

### 5. Read-only LLM judgment

The reviewer always sees trusted deterministic context, the full diff path,
and a clearly delimited untrusted block containing sanitized PR-authored text
and reviewer discussion. The prompt directs it to find showstoppers, verify
claims against source, require independent assurance in risky territory, and
escalate on prompt injection. Folder guidance remains untrusted advisory text
and cannot override gates or refusal criteria.
([`reviewer.py`](https://github.com/PostHog/posthog/blob/f2218147c5f0cb6dcf6684e2d24dd0c4d63ed28b/tools/pr-approval-agent/reviewer.py#L172-L258),
[`reviewer.py`](https://github.com/PostHog/posthog/blob/f2218147c5f0cb6dcf6684e2d24dd0c4d63ed28b/tools/pr-approval-agent/reviewer.py#L418-L565))

### 6. Combine verdict and publish

The model returns one of `APPROVE`, `REFUSE`, or `ESCALATE`; the orchestrator
combines it with the gate result monotonically. PostHog's workflow maps only
final `APPROVED` to real GitHub approval reviews. All other outcomes update one
sticky comment. `REFUSED` and `ESCALATE` remove the label so the author must
address feedback and opt in again; `WAIT`, `ERROR`, and a verdictless crash
retain it so a later push retries.
([`review_pr.py`](https://github.com/PostHog/posthog/blob/f2218147c5f0cb6dcf6684e2d24dd0c4d63ed28b/tools/pr-approval-agent/review_pr.py#L709-L741),
[workflow](https://github.com/PostHog/posthog/blob/f2218147c5f0cb6dcf6684e2d24dd0c4d63ed28b/.github/workflows/pr-approval-agent.yml#L109-L249))

PostHog currently posts two commit-bound approvals: one with the GitHub App
identity and body, plus one bodyless `github-actions[bot]` approval while it
confirms which identity satisfies branch protection. That duplication is an
operational workaround, not a core safety invariant.
([README](https://github.com/PostHog/posthog/blob/f2218147c5f0cb6dcf6684e2d24dd0c4d63ed28b/tools/pr-approval-agent/README.md#L136-L145))

## Configuration schema and gate semantics

The trusted global file is `.stamphog/policy.yml`. Its validated top-level
schema is:

```yaml
version: integer
deny:
  <category>:
    description: string
    rationale: string
    match:
      any: [regex, ...]       # paths hard-deny; titles flag scrutiny
      paths: [regex, ...]     # path matching only
      titles: [regex, ...]    # title scrutiny only
    exempt_path_prefixes: [repo/relative/prefix/, ...]
allow:
  path_patterns: [substring, ...]
  extensions_only: [.ext, ...]
size_gate:
  max_lines: integer
  max_files: integer
tiers:
  t1_subclasses:
    <ordered-name>:
      max_lines: integer
      max_files: integer
      breadth: single-area | not-cross-cutting
dismiss:
  trivial_extensions: [.ext, ...]
  trivial_name_prefixes: [name, ...]
  test_regex: regex
  generated_regex: regex
overrides:
  size_gate.max_files:
    ceiling: integer
familiarity:
  strong:
    min_blame_overlap_pct: number
  moderate:
    min_prior_prs: positive-integer
    max_days_since_touch: positive-integer
ownership:
  sources:
    - format: registered-format
      path: repo-relative-path   # or the format's required `glob`
```

The loader validates types, regex compilation, allowed enum values, exact
ownership locator shape, repo-relative paths, self-governance coverage, and
the one-key delegation contract. A malformed global policy raises instead of
partially loading.
([`policy.py`](https://github.com/PostHog/posthog/blob/f2218147c5f0cb6dcf6684e2d24dd0c4d63ed28b/tools/pr-approval-agent/policy.py#L88-L221),
[`policy.py`](https://github.com/PostHog/posthog/blob/f2218147c5f0cb6dcf6684e2d24dd0c4d63ed28b/tools/pr-approval-agent/policy.py#L226-L430))

### Deny and title scrutiny

Only changed file paths hard-deny. The same sensitive keyword in a title is a
scrutiny flag requiring the model to verify whether the diff behaviorally
enters that domain. PostHog's categories are auth, cryptography/secrets,
migrations, infra/CI/CD, billing, public API, dependencies/toolchain, and the
agent's own policy/engine. These names and patterns are codebase-specific, not
portable defaults.
([`gates.py`](https://github.com/PostHog/posthog/blob/f2218147c5f0cb6dcf6684e2d24dd0c4d63ed28b/tools/pr-approval-agent/gates.py#L463-L502),
[`policy.yml`](https://github.com/PostHog/posthog/blob/f2218147c5f0cb6dcf6684e2d24dd0c4d63ed28b/.stamphog/policy.yml#L5-L131))

Dependency manifests do not automatically deny. Lockfiles and executable
toolchain/build files do; manifests without their ecosystem lockfile are kept
out of T0 and structurally scanned for scripts, lifecycle hooks, and build
configuration. An unreadable manifest diff is risky by default.
([README](https://github.com/PostHog/posthog/blob/f2218147c5f0cb6dcf6684e2d24dd0c4d63ed28b/tools/pr-approval-agent/README.md#L186-L198),
[`manifest_risk.py`](https://github.com/PostHog/posthog/blob/f2218147c5f0cb6dcf6684e2d24dd0c4d63ed28b/tools/pr-approval-agent/manifest_risk.py#L112-L177))

PostHog has one repo-specific deterministic exception: migration files may
bypass the migration deny category only when a named check run on the exact
head succeeds and reports those files safe. Pending status refuses rather
than guessing.
([README](https://github.com/PostHog/posthog/blob/f2218147c5f0cb6dcf6684e2d24dd0c4d63ed28b/tools/pr-approval-agent/README.md#L200-L206),
[`migration_risk.py`](https://github.com/PostHog/posthog/blob/f2218147c5f0cb6dcf6684e2d24dd0c4d63ed28b/tools/pr-approval-agent/migration_risk.py#L32-L108))

### Size ceiling

PostHog denies automatic review above **800 substantive changed lines** or
**30 substantive files**. Prose docs, tests, snapshots, images, `.lock`
extension files, and narrowly defined generated artifacts are excluded from
this hard ceiling, but remain visible in the diff and still count for tier
classification. Runtime-bearing JSON/YAML/TOML config remains substantive.
([README](https://github.com/PostHog/posthog/blob/f2218147c5f0cb6dcf6684e2d24dd0c4d63ed28b/tools/pr-approval-agent/README.md#L66-L80),
[`gates.py`](https://github.com/PostHog/posthog/blob/f2218147c5f0cb6dcf6684e2d24dd0c4d63ed28b/tools/pr-approval-agent/gates.py#L558-L617))

Folder-level `AGENT_APPROVALS.md` files may only raise their own substantive
file budget, within the global contract ceiling. They cannot delegate line
limits, deny/allow patterns, tiers, dismissal rules, or familiarity. Mixed PRs
retain separate scope budgets, so a lenient subtree cannot subsidize unrelated
files. Invalid folder configuration contributes no override.
([`policy.py`](https://github.com/PostHog/posthog/blob/f2218147c5f0cb6dcf6684e2d24dd0c4d63ed28b/tools/pr-approval-agent/policy.py#L186-L218),
[`policy.py`](https://github.com/PostHog/posthog/blob/f2218147c5f0cb6dcf6684e2d24dd0c4d63ed28b/tools/pr-approval-agent/policy.py#L562-L663))

### Tiers

- **T2-never**: any deny category; the tier gate fails.
- **T0-deterministic**: no deny, no new files, and every path is allowlisted or
  all files are tests. Dependency manifest changes are deliberately excluded.
  Despite the name, the current pipeline still asks the LLM to confirm or flag
  concerns with a lighter bar.
- **T1-agent**: everything else eligible, sub-classified by raw total lines,
  files, and breadth. PostHog uses T1a `<=20/<=3/single-area`, T1b
  `<=100/<=5/not-cross-cutting`, T1c `<=300/<=15/not-cross-cutting`, and T1d as
  fallback.

([`gates.py`](https://github.com/PostHog/posthog/blob/f2218147c5f0cb6dcf6684e2d24dd0c4d63ed28b/tools/pr-approval-agent/gates.py#L620-L671),
[`reviewer.py`](https://github.com/PostHog/posthog/blob/f2218147c5f0cb6dcf6684e2d24dd0c4d63ed28b/tools/pr-approval-agent/reviewer.py#L481-L487),
[`policy.yml`](https://github.com/PostHog/posthog/blob/f2218147c5f0cb6dcf6684e2d24dd0c4d63ed28b/.stamphog/policy.yml#L132-L187))

### Ownership and familiarity

Ownership and git-history familiarity are advisory model context, never hard
gates. PostHog unions soft CODEOWNERS with product metadata. Owning-team
membership or strong blame overlap can count as independent assurance in
risky territory; moderate familiarity is weaker context. Failures computing
familiarity leave the signal absent and do not alter gates.
([README](https://github.com/PostHog/posthog/blob/f2218147c5f0cb6dcf6684e2d24dd0c4d63ed28b/tools/pr-approval-agent/README.md#L208-L217),
[`review-guidance.md`](https://github.com/PostHog/posthog/blob/f2218147c5f0cb6dcf6684e2d24dd0c4d63ed28b/.stamphog/review-guidance.md#L37-L82))

## LLM role and containment

The current implementation uses the Claude Agent SDK with
`claude-sonnet-5`. It grants only `Read`, `Grep`, and `Glob`; explicitly denies
write/edit, Bash, subagents, and web tools; uses `dontAsk`; disables session
persistence; and caps quick reviews at five turns and other reviews at twenty.
([`reviewer.py`](https://github.com/PostHog/posthog/blob/f2218147c5f0cb6dcf6684e2d24dd0c4d63ed28b/tools/pr-approval-agent/reviewer.py#L1-L44),
[`reviewer.py`](https://github.com/PostHog/posthog/blob/f2218147c5f0cb6dcf6684e2d24dd0c4d63ed28b/tools/pr-approval-agent/reviewer.py#L269-L310))

Its structured result schema has exactly four fields: verdict
(`APPROVE|REFUSE|ESCALATE`), short reasoning, risk (`low|medium|high`), and an
issues array. The model searches for production breakage, security problems,
missed risky domains, and substantive unresolved review concerns. In risky
territory, it aggregates independent assurance rather than certifying the
change by itself; outside risky territory, its own reading can suffice.
([`reviewer.py`](https://github.com/PostHog/posthog/blob/f2218147c5f0cb6dcf6684e2d24dd0c4d63ed28b/tools/pr-approval-agent/reviewer.py#L130-L169),
[`review-guidance.md`](https://github.com/PostHog/posthog/blob/f2218147c5f0cb6dcf6684e2d24dd0c4d63ed28b/.stamphog/review-guidance.md#L1-L36))

The prompt treats PR title/body, filenames, diff, comments, and folder guidance
as untrusted content. Invisible/control characters are stripped and fields are
length-capped. Review metadata-derived assurance remains in the trusted block.
This is prompt-injection mitigation, not a substitute for the model's OS/tool
containment or the deterministic final-verdict combiner.
([`policy.py`](https://github.com/PostHog/posthog/blob/f2218147c5f0cb6dcf6684e2d24dd0c4d63ed28b/tools/pr-approval-agent/policy.py#L23-L51),
[`reviewer.py`](https://github.com/PostHog/posthog/blob/f2218147c5f0cb6dcf6684e2d24dd0c4d63ed28b/tools/pr-approval-agent/reviewer.py#L172-L185),
[`reviewer.py`](https://github.com/PostHog/posthog/blob/f2218147c5f0cb6dcf6684e2d24dd0c4d63ed28b/tools/pr-approval-agent/reviewer.py#L523-L563))

## GitHub identities, credentials, and artifacts

PostHog supplies a dedicated GitHub App ID/private key to mint the token used
for fetching data, commenting, labels, and the App-identity approval. The
workflow also uses the job's `github.token` for its second approval and stale
approval dismissal. The LLM receives a dedicated
`STAMPHOG_ANTHROPIC_API_KEY` exposed under the SDK's expected
`ANTHROPIC_API_KEY`; optional AI-gateway URL/key and PostHog API token support
routing and traces.
([workflow](https://github.com/PostHog/posthog/blob/f2218147c5f0cb6dcf6684e2d24dd0c4d63ed28b/.github/workflows/pr-approval-agent.yml#L44-L106))

Every run emits a JSON evidence bundle containing PR/head metadata,
classification, gate results, reviewer output, final verdict, engine version,
and policy provenance. CI uploads it for 30 days. Engine/prompt behavior has a
semantic version; policy-only changes rely on the policy SHA instead.
([README](https://github.com/PostHog/posthog/blob/f2218147c5f0cb6dcf6684e2d24dd0c4d63ed28b/tools/pr-approval-agent/README.md#L219-L248),
[workflow](https://github.com/PostHog/posthog/blob/f2218147c5f0cb6dcf6684e2d24dd0c4d63ed28b/.github/workflows/pr-approval-agent.yml#L244-L251))

## What must be re-derived for awesoMux

The reusable pieces are the monotonic pipeline, trusted-base execution,
self-governance deny, read-only reviewer, verdict combiner, sticky-comment
behavior, commit-bound approvals, and stale-approval lifecycle. The following
are PostHog policy, not architecture, and require awesoMux evidence:

- deny categories, path/title regexes, and any exemptions;
- substantive-file exemptions;
- hard maximum substantive lines/files;
- T1 sub-tier line/file/breadth ceilings;
- safe post-approval delta paths;
- ownership sources and what counts as independent assurance;
- any check-run-based deny exception;
- reviewer bot allowlist and wait timings;
- trigger label, GitHub identity, model/SDK, and credential route.

PostHog's own calibration used quickly human-approved PRs plus later denial
outcomes, and specifically found that tiny changes in auth or CI remain too
risky for automated approval. awesoMux should therefore mine merged PRs for
both the normal auto-approval envelope and small high-blast-radius exceptions,
rather than scaling PostHog's numeric limits by repository size.
([README](https://github.com/PostHog/posthog/blob/f2218147c5f0cb6dcf6684e2d24dd0c4d63ed28b/tools/pr-approval-agent/README.md#L250-L262))
