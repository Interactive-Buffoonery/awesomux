# PR approval agent harness research

**Date:** 2026-07-11
**Scope:** Choose the runtime harness for awesoMux's fail-closed PR approval
agent using Synthetic's OpenAI-compatible Chat Completions API and the pinned
`hf:moonshotai/Kimi-K2.7-Code` model.

## Recommendation

Do not keep OpenCode as the approval authority. Preserve `/oc` as a user-facing
review-only trigger if desired, but route it to the same new engine.

Rank the harnesses:

1. **Minimal direct `openai-python` tool loop with local Pydantic validation**
2. **PydanticAI**
3. **OpenAI Agents SDK for Python**
4. **OpenCode**

The direct loop best matches this unusually narrow job. The workflow, not the
model runtime, should own deterministic gates, exact-head checks, GitHub writes,
and the transition from a validated verdict to an approval. The model runtime
should be limited to a closed set of bounded, read-only tools and one typed
verdict channel.

This recommendation does not change the safety architecture:

- Deterministic gates run before the LLM and remain authoritative.
- The LLM may tighten a gate outcome but may never loosen one.
- Every runtime, provider, validation, budget, or stale-head error produces no
  approval.
- The agent never requests changes and never merges.
- Only the outer trusted workflow may post an approval, and only after it
  refetches the PR and confirms the reviewed head SHA is still current.

That separation follows PostHog's architecture: deterministic classification
and gates precede an LLM limited to read/search tools; gates are authoritative;
and only an approval becomes a GitHub review while all other verdicts become a
sticky comment. PostHog explicitly says its bot never requests changes.
([PostHog approval-agent README](https://github.com/PostHog/posthog/blob/master/tools/pr-approval-agent/README.md))

## Why a direct loop is the best fit

Synthetic documents an OpenAI-compatible Chat Completions endpoint with
`tools`, `tool_choice`, `parallel_tool_calls`, `response_format`, explicit
completion-token limits, and normal usage data. It also lists Kimi K2.7 Code as
an included 256k-context model. The provider contract is therefore small enough
to exercise directly rather than through a general coding-agent runtime.
([Synthetic Chat Completions](https://dev.synthetic.new/docs/openai/chat-completions),
[Synthetic models](https://dev.synthetic.new/docs/api/models))

Use the official `openai-python` client only as the HTTP/type layer and implement
the loop in repository-owned code:

- Send only the exact schemas for bounded `read`, `grep`, and `glob` tools.
- Dispatch tool calls through a closed name-to-function map. There is no shell,
  edit, GitHub, network, subagent, MCP, plugin, or arbitrary command facility to
  deny because none is registered.
- Validate every tool argument locally before execution; reject unknown tools,
  malformed arguments, out-of-root paths, oversized ranges/results, parallel
  calls, and repeated-call abuse.
- End only through a `submit_verdict` function tool whose arguments are
  validated by a strict local Pydantic model. Treat plain text, malformed JSON,
  multiple verdict calls, an invalid enum, or a missing verdict as `ERROR`.
- Enforce explicit request, turn, successful-tool-call, per-tool-output,
  cumulative-context, and completion-token ceilings in the loop.
- Set a short explicit timeout and deliberately configure SDK retries. The
  OpenAI client otherwise retries selected connection, timeout, conflict,
  rate-limit, and server errors twice by default, and its default timeout is ten
  minutes. For predictable quota use, start with `max_retries=0`; if a transport
  retry is later allowed, make it an explicit, audited orchestration decision.
  ([OpenAI Python retries and timeouts](https://github.com/openai/openai-python#retries))
- Keep no session state and perform no compaction or summarization in the
  authoritative run.

The OpenAI Python SDK supports custom `base_url`, timeout, and retry settings;
its Pydantic helpers can generate strict function schemas and parse strict tool
arguments. It has a substantially smaller runtime dependency surface than an
agent framework: its project file lists eight direct runtime dependencies,
while the Agents SDK adds its own framework plus MCP, WebSocket, tracing, and
agent machinery on top of `openai-python`.
([OpenAI structured-output helpers](https://github.com/openai/openai-python/blob/main/helpers.md),
[`openai-python` package metadata](https://github.com/openai/openai-python/blob/main/pyproject.toml),
[Agents SDK package metadata](https://github.com/openai/openai-agents-python/blob/main/pyproject.toml))

Do not assume that OpenAI's `chat.completions.parse(response_format=...)`
behaves identically through Synthetic and Kimi. The safer V1 terminal channel
is a strict `submit_verdict` function tool plus local validation, because tool
calling is already required for repository exploration. Native JSON-schema
output can replace it only after the provider contract tests prove the exact
behavior.

## Comparison

| Criterion | Direct `openai-python` loop | PydanticAI | OpenAI Agents SDK | OpenCode |
| --- | --- | --- | --- | --- |
| Mechanical tool boundary | Strongest: only schemas and dispatchers written into the loop exist | Strong: only registered tools/toolsets are exposed | Strong: only `Agent(tools=[...])` tools are exposed | Weaker fit: built-ins are enabled by default and must be denied through merged configuration |
| Typed verdict | Local strict Pydantic validation; caller defines every failure | Excellent built-in typed outputs, validators, and bounded output retries | Built-in `output_type`; malformed output raises model-behavior errors | SDK has structured output, but current GitHub CLI path is text-oriented and awesoMux scrapes logs for a heading |
| Synthetic/Kimi fit | Direct match to documented Chat Completions wire contract | Uses `OpenAIChatModel` with a custom `OpenAIProvider`; needs profile/contract validation | Uses `OpenAIChatCompletionsModel` with a custom client; non-OpenAI compatibility must be validated | Synthetic is a native provider and is known to run today |
| Hard budgets | Must implement, but every counter is visible and testable | Best framework support: request, tool-call, input/output/total-token limits | Has `max_turns` and usage aggregation; less direct pre-execution budget support | `steps` forces a summary instead of raising; wrappers must detect that non-verdict state |
| Retry semantics | Entirely explicit; SDK retries can be disabled | Explicit validation retries and framework usage exceptions | Explicit model retry policy plus runner exceptions | Interactive recovery, provider retries, compaction, and wrapper retries add hidden paths |
| Tracing/session behavior | No tracing or sessions unless added | Logfire/instrumentation can remain unused; do not pass history | Tracing is on by default and must be disabled; do not use sessions/handoffs | Session, compaction, title, summary, plugins, and config discovery are core runtime concerns |
| Auditability | Best: one small loop and a deterministic event ledger | Good, but framework events and provider profiles add interpretation | Good, but broader runner lifecycle and tracing defaults | Lowest for this task: CLI/server/config/plugin behavior plus log parsing and GitHub writeback paths |
| Supply-chain surface | Smallest | Medium (`pydantic-ai-slim[openai]` still adds an agent framework) | Medium/high | Highest: general coding agent, installer, provider adapters, plugins, MCP/LSP, and GitHub integration |

## Runner-up: PydanticAI

PydanticAI is the best ready-made harness if the direct loop proves expensive to
maintain. It supports `OpenAIChatModel` against a custom OpenAI-compatible base
URL/client, typed outputs, local tool-argument validation, output validators,
and controlled validation retries.
([PydanticAI OpenAI-compatible models](https://pydantic.dev/docs/ai/models/openai/#openai-compatible-models),
[PydanticAI outputs](https://pydantic.dev/docs/ai/core-concepts/output/))

Its strongest advantage is `UsageLimits`: request count is checked before each
model request, successful tool calls are checked before execution, and token
limits are checked from provider-reported response usage. It raises
`UsageLimitExceeded` when a limit is crossed. The default request limit is 50,
so awesoMux would still set much tighter explicit values.
([PydanticAI usage limits](https://pydantic.dev/docs/ai/api/pydantic-ai/usage/#pydantic_ai.usage.UsageLimits))

Reasons it ranks second:

- The use case needs only a short loop, three read-only tools, and one verdict;
  most framework functionality would be unused.
- Automatic validation feedback and retries are useful but consume tokens and
  introduce behavior that must be included in the audit model.
- Token-limit enforcement depends on provider-reported usage and occurs after a
  response. Request/tool ceilings and API completion-token limits remain the
  primary pre-execution controls.
- Synthetic/Kimi still needs the same contract suite, including whether a
  custom model profile is necessary for strict tools or structured output.

If selected, use `pydantic-ai-slim` with only its OpenAI extra, no Logfire,
history, durable execution, MCP, fallback models, or output functions with side
effects.

## Third: OpenAI Agents SDK

The Agents SDK is viable. It supports a custom `AsyncOpenAI` client and
`OpenAIChatCompletionsModel`, explicitly registered function tools, typed
`output_type`, `max_turns`, usage aggregation, and exceptions for malformed
model behavior and exceeded turns.
([Agents SDK model providers](https://openai.github.io/openai-agents-python/models/),
[Agents SDK run loop](https://openai.github.io/openai-agents-python/running_agents/),
[Agents SDK agents](https://openai.github.io/openai-agents-python/agents/))

It ranks below PydanticAI for this job because:

- PydanticAI has clearer first-class request, token, and successful-tool-call
  budgets; the Agents SDK's main built-in ceiling is model turns.
- The SDK includes handoffs, guardrails, sessions, MCP support, and tracing that
  this single-agent workflow does not need.
- Tracing captures generations and tool calls and is enabled by default. With a
  non-OpenAI provider it must be disabled explicitly for every run (and ideally
  again by environment) so repository content is not sent to another service.
  ([Agents SDK tracing](https://openai.github.io/openai-agents-python/tracing/))
- The official docs warn that many non-OpenAI providers support Chat
  Completions rather than Responses. awesoMux would have to pin
  `OpenAIChatCompletionsModel`, enable strict feature validation where
  applicable, and contract-test tool, output, and usage behavior.

If this SDK is used, configure no handoffs or sessions, disable tracing, keep
the default unknown-tool behavior that raises `ModelBehaviorError`, set a tight
`max_turns`, and treat every exception as a non-approval.

## Last: OpenCode

OpenCode is a good interactive coding agent and already works with Synthetic,
but it is the wrong abstraction for an approval authority.

Official OpenCode documentation says all built-in tools are enabled by default;
permissions then allow, ask, or deny them. Its permission system can express
awesoMux's current read-only policy, but safety depends on exhaustively denying
current and future ambient capabilities rather than constructing only the three
capabilities the reviewer needs.
([OpenCode tools](https://opencode.ai/docs/tools/),
[OpenCode agent permissions](https://opencode.ai/docs/agents/#permissions))

Its step limit is also not a fail-closed exception. When the configured number
of iterations is reached, OpenCode forces a text-only summary of work and
remaining tasks; without a limit it runs until the model stops or the user
interrupts. An approval wrapper must distinguish that summary from a valid
verdict.
([OpenCode max steps](https://opencode.ai/docs/agents/#max-steps))

The live awesoMux integration demonstrates the resulting containment work:

- Three workflows split automatic reviews, synchronize reminders, and `/oc`.
- A composite action installs and version-checks OpenCode through a remote
  installer and maintains its cache.
- Trusted default-branch helpers are checked out separately because PR files
  are untrusted while model and GitHub credentials are in scope.
- Project config discovery is disabled or redirected to avoid PR-controlled
  agents, plugins, and tools.
- Shell wrappers scrape version-specific log markers, detect quota failures by
  regular expression, kill process groups, and retry narration-only runs.
- A git-identity defense exists because OpenCode's GitHub path can attempt a
  commit when it sees a dirty branch, even though this use is intended to be
  review-only.
- The reviewed set spans roughly 2,589 lines across workflows, action wrappers,
  parsers/tests, and OpenCode agent/skill configuration. Some of that code is
  valuable review UX rather than harness overhead, but much of it exists to
  constrain or interpret a general-purpose coding agent.

OpenCode's own GitHub documentation centers a runtime that can comment, commit,
create branches, and open PRs. That is broader than an approval reviewer whose
model process must have no GitHub-write capability.
([OpenCode GitHub integration](https://opencode.ai/docs/github/))

Preserving `/oc` does not require preserving OpenCode. The command can trigger
the new engine in review-only mode, where even a validated `APPROVE` verdict is
rendered as a comment and never submitted as a GitHub approval.

## Exact-SHA approval boundary

Harness choice should not affect GitHub authority. The trusted outer workflow
must:

1. Capture the PR head SHA before gates and model work.
2. Bind the audit record, diff, prompts, tool calls, and verdict to that SHA and
   the exact pinned model ID.
3. After a validated `APPROVE`, refetch the PR and compare its current head SHA
   with the reviewed SHA.
4. Post no approval on mismatch, missing data, API error, or ambiguous state.
5. If they match, create an `APPROVE` review with `commit_id` set explicitly to
   the reviewed SHA.

GitHub's create-review endpoint accepts `commit_id`; if omitted it defaults to
the PR's most recent commit. Supplying it explicitly is therefore required for
an auditable exact-SHA approval.
([GitHub pull-request review API](https://docs.github.com/en/rest/pulls/reviews?apiVersion=2022-11-28#create-a-review-for-a-pull-request))

The model never receives a GitHub token and cannot invoke this step. It can only
return a candidate verdict to deterministic code.

## Required Synthetic/Kimi contract suite

Before any live review or historical replay, test the wire behavior against the
pinned model. These are provider contracts, not assumptions inherited from any
harness:

1. Exact model ID is accepted and the response reports an expected model
   identity. No alias or silent fallback is accepted.
2. A single strict function tool call returns a stable tool-call ID and valid
   JSON arguments.
3. Unknown-tool and malformed-argument prompts cannot escape the closed
   dispatcher.
4. `parallel_tool_calls: false` prevents multiple concurrent calls; receiving
   multiple calls anyway is an error.
5. Tool results round-trip correctly through `tool_call_id`.
6. `max_completion_tokens`, timeouts, and finish reasons are surfaced as
   expected. `length` is an error, never an implicit verdict.
7. Usage fields are present and internally consistent. Missing or malformed
   usage fails the authoritative run until an explicitly approved accounting
   policy exists.
8. The strict `submit_verdict` schema works repeatedly; invalid, duplicate, or
   mixed text/tool verdicts fail closed.
9. 429, quota exhaustion, 5xx, disconnect, timeout, and truncated JSON all end
   without approval and with a deterministic error record.
10. Tool outputs at every configured size boundary are truncated or rejected
    deterministically and cannot traverse outside the checked-out repository.

Run these tests first with a fake transport, then against Synthetic/Kimi. The
historical 50-PR replay and 10-live-PR review-only pilot should evaluate review
quality only after the transport and safety contracts pass. Revisit the harness
choice after the pilot if direct-loop maintenance or model compatibility is
materially worse than expected; PydanticAI is the intended fallback.

## Audit record

For every run, retain a machine-readable record containing at least:

- repository, PR number, captured base/head SHAs, and final refetched head SHA;
- gate configuration version and every deterministic gate result;
- exact provider endpoint class, pinned model ID, harness/package versions, and
  prompt/schema hashes;
- request count, turn count, successful tool-call count, token usage, finish
  reasons, and provider request IDs when available;
- each tool name, validated arguments, bounded output size/hash, and error;
- the validated verdict or terminal error category;
- the GitHub action taken, review ID, and approved commit ID, if any.

Do not depend on provider tracing or hidden session state as the audit record.
The repository-owned record should be sufficient to explain why a particular
SHA was or was not approved without storing model chain-of-thought.
