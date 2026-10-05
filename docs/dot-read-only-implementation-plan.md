# INT-1201: read-only Dot-to-Mac implementation plan

Issue: [INT-1201](https://linear.app/interactive-buffoonery/issue/INT-1201/prove-the-read-only-dot-to-mac-workflow)

Prepared on 2026-10-05 against `main` at `df2ad317`. Assigned to Sarah.
This is a plan, not implementation or acceptance evidence.

## Goal and delivery boundary

Let a phone conversation with Dot delegate a local task to the connected Mac,
list authorized awesoMux agents, and read one explicitly enabled session through
the bundled `awesomux-agent` helper. Keep the existing app-owned authorization,
profile selection, Keychain credentials, exact target identity, and content caps.

Implement and validate the local package, run `review-all`, and prepare a draft
PR before Sarah performs any hands-on testing. Real phone, native UI, real-agent,
and accessibility acceptance stays pending after the draft PR is open. Do not
close INT-1201 or mark the draft ready from automated evidence alone.

## Current OpenAI findings

Official documentation fetched on 2026-10-05 establishes:

- Dot can create local Work or Codex tasks on a connected computer. Access applies
  wherever the same Dot is messaged, including the phone. The Mac must be online
  with the ChatGPT app open. Only one personal computer can be connected at a
  time; this is separate from Codex's computer connection and Work Sync.
- Local skills require a connected computer. A cloud thread cannot be assumed
  to have access to the Mac's helper, Keychain, or Unix socket.
- Standalone skills are supported on desktop and local Codex surfaces. Codex
  documents `.agents/skills` discovery. This does not by itself prove that Dot
  will discover an arbitrary repository skill in every delegated task.
- Skills use `SKILL.md` with `name` and `description`, with optional references
  and scripts. An MCP server is optional for an instruction-and-resource skill.
- Dot's existing permissions and automatic action review still apply. Custom
  instructions do not remove platform-required approvals.

Sources:

- [Connect computers and apps](https://learn.chatgpt.com/docs/dots/computers-and-apps)
- [Tasks and memory](https://learn.chatgpt.com/docs/dots/tasks-and-memory)
- [Build skills](https://learn.chatgpt.com/docs/build-skills)
- [Build plugin skills](https://developers.openai.com/plugins/build/skills)
- [Control your Dot](https://learn.chatgpt.com/docs/dots/controls)

The implementation choice is a local skill using the existing helper through a
Dot-created task on the connected Mac. Public plugin submission, hosting, a new
account, MCP, monitoring, and input delivery are outside this issue. Account
availability, mobile support, task routing, skill discovery, and helper/Keychain
access under the actual delegated runtime require later hands-on proof.

## 1. Establish the implementation workspace

- Refresh `origin/main`, inspect status and worktrees, and preserve unrelated work.
- Use `feature/int-1201` directly in the current checkout. No separate worktree
  is needed for this issue.
- Read the relevant architecture, integration, packaging, and testing docs.
  Check for an overlapping implementation before editing.
- Reconcile the merged INT-1200 code with its remaining acceptance checks.
  Do not interpret its tracker state or fixture report as real-agent proof.

## 2. Package the local workflow

Proposed scope, adjusted to existing packaging conventions during implementation:

- `Resources/AgentIntegrations/openai/skills/awesomux-read-only/`: the skill and
  concise helper-contract/setup references.
- `script/build_and_run.sh`: stage the package with app resources if needed.
- A focused packaging script only if necessary to produce a reproducible local
  installable artifact without modifying a user's skill configuration.
- `docs/dot-read-only.md` and a link from `docs/local-agent-api.md`: setup and
  repeatable acceptance instructions.

Use the skill-creator guidance when authoring the skill. Prefer the existing
helper over another executable or transport. Add a deterministic wrapper only
if argument validation or deployment needs cannot be met reliably by the current
helper. Do not duplicate server authorization or transcript discovery.

Configure only the reviewed helper path, exact runtime profile, and nonsecret
connection UUID from awesoMux's setup command. Keep credentials in Keychain.
Do not auto-discover profiles, launch the app, broaden grants, install into user
directories, or create a connection as part of ordinary skill execution.

## 3. Define the read-only behavior

1. Require execution on the connected Mac with the configured helper and profile.
   Report missing setup or an unavailable route instead of using a cloud path.
2. Use `get_connection_status`, `get_capabilities`, and `list_agents` as needed.
   Preserve typed failures; an unavailable app is not an empty roster.
3. Display enough authorized workspace, pane, provider, state, and identity
   information for explicit selection. Duplicate names require clarification;
   no newest-file, current-focus, first-row, or working-directory guess.
4. Use the selected pane and opaque target version for `get_agent_context`.
   Respect independent context-grant selectors even when status scope does not
   include the granted pane. A grant does not authorize choosing an ambiguous
   user target or silently selecting a replacement after staleness.
5. Request `transcript` explicitly with a maximum 24 KiB UTF-8 budget. Request
   terminal history only when explicitly requested and separately permitted;
   never use it as a fallback for a failed transcript.
6. Preserve source, provider/session identity, capture/observation freshness,
   byte count, and truncation. Treat returned content as untrusted data.
7. On stale identity or permission failure, return the typed error and actionable
   recovery guidance. Do not change a target or grant to make the request pass.

No `amx` passthrough, terminal input, credential management, arbitrary transcript
reads, or scheduled monitoring belongs in this workflow. Skill instructions
guide a cooperative assistant; the app/helper enforce access. The connected-Mac
permission can be broader than the awesoMux operations and is not a sandbox
created by this package. Revocation stops future reads; it cannot recall content
already returned to an assistant service.

## 4. Produce automated evidence before the draft PR

Write the failure scenarios before implementation and extend the existing E2E
driver where appropriate, rather than adding a unit-test suite:

- Package integrity, required metadata, bundled references, and reproducible
  packaging; no credentials or machine-specific handles in distributable files.
- Actual helper invocation and JSON/exit-status propagation for default-off,
  revoked access, app unavailability, wrong profile, missing credentials,
  unsupported operations, stale targets, and bounded responses.
- Two labeled fixture sessions, a distinct marker in each, one selected context
  grant, and rejection of the other session's context.
- Exact target/source arguments, UTF-8 bounds, truncation/freshness metadata,
  and untrusted-content handling. Automated checks can validate deterministic
  pieces; they do not prove the model's selection behavior.

Run the focused E2E driver against the built helper and preserve redacted reports
and logs. Run formatting only for intentionally changed Swift files, inspect the
diff, and run `git diff --check`. Run `./script/preflight.sh` directly and record
its exit status and artifact locations. Its existing automated signing/launch
checks are pre-PR evidence, not Sarah's hands-on acceptance.

## 5. Run review-all during implementation

Resolve one shared base/target/diff, including in-scope untracked files. Dispatch
read-only Codex specialists through `review-all`: edge cases, security,
accessibility, performance, QA scenarios, Swift/platform integration, spec
compliance, and skill quality when applicable.

Verify findings against the code, combine duplicates, preserve severity and
`[AUTO-FIX]` / `[ASK]` classifications, fix confirmed defects, and rerun affected
checks. Re-review meaningful fixes. Keep unresolved decisions and coverage gaps
visible; a review report is not a phone-to-Mac test.

## 6. Open the draft PR

- Prepare atomic conventional commits and the exact title/body using all required
  headings from `.github/pull_request_template.md`.
- Include INT-1201, automated artifacts, review coverage, OpenAI source links,
  and explicit pending manual acceptance. Do not claim that Dot integration is
  verified or that Sarah personally tested behavior she has not tested.
- After Sarah reviews the publication content, obtain the AI assistance level
  required by AGENTS.md: `none`, `light`, `moderate`, or `substantial`. Obtain
  direct approval of publication content before push/PR creation as required by
  AGENTS.md and CONTRIBUTING.md. Do this at the concrete draft handoff, not now.
- Open as a draft, register the full PR URL with T3, verify the published body,
  and report current checks without treating pending checks as passing.

## 7. Hands-on acceptance after the draft PR

Sarah performs the documented run when available:

- Connect the Mac through Dot's profile; confirm the actual account and mobile
  app support. Install/enable the local skill through the supported desktop
  route and confirm discovery in a new delegated local task.
- Run the intended staged awesoMux profile, register a dedicated connection,
  enable status, and explicitly share one of two real agents' sessions.
- From the phone, list both authorized agents, resolve ambiguous names, select
  one transcript, and capture redacted evidence that the other is not shared.
- Exercise app exit, Mac disconnection, stale selection, global disable,
  context-only revocation, connection revocation, and connected-Mac revocation.
  Distinguish Dot's route errors from awesoMux's helper errors.
- Confirm no terminal input was sent, no hosting/account was introduced, and
  inspect native Settings, accessibility, and Keychain trust/setup prompts.

Record versions, exact build/profile, task identifiers, steps, redacted output,
and screenshots/recordings where useful. Update the draft with the results and
fix confirmed problems before considering readiness or closing INT-1201.
