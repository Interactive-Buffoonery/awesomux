# Agent Status Plugin Parsing + Cross-Provider Event Contamination Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix two independently-confirmed bugs: (1) the Settings panel always reports every agent CLI plugin as "Not installed" regardless of real state, and (2) a subprocess CLI invocation (e.g. `codex exec` run as a Bash tool call inside a Claude Code pane) can silently overwrite that pane's tracked agent identity and execution state because it inherits the pane's hook-event file.

**Architecture:** Both fixes are narrow, single-file changes to existing pure functions with existing unit-test coverage patterns to extend. No new types, no new files beyond tests.

**Tech Stack:** Swift, SwiftPM, swift-testing (`@Suite`/`@Test`/`#expect`).

## Global Constraints

- Follow `AGENTS.md`: Conventional Commits, `<type>(<scope>): <lowercase imperative>`, subject <=72 chars, no period.
- New tests use swift-testing (`@Suite`/`@Test`/`#expect`), not XCTest.
- No code comments narrating *what* the code does — only *why*, when non-obvious.
- Don't add abstractions or config beyond what each fix requires.

## Background (read before starting either task)

### Task 1 background: plugin-list JSON schema change

`claude plugin list --json` (verified live against Claude Code CLI 2.1.217) now
emits each entry as a flat `id` field (`"awesomux-claude-status@awesomux-claude"`),
not the separate `name`/`marketplace` fields `ClaudePluginListEntry` currently
decodes. Since those keys are absent from the real payload,
`ClaudePluginListEntry.name` silently decodes to `nil` for every entry, so
`ClaudePluginListEntry.matches(_:)` always returns `false`, and
`claudeMapList` always falls through to `.notInstalled` — regardless of
whether the plugin is actually installed and enabled. This does not affect
whether hooks actually fire (`AgentRuntimeConsent.allows` in
`Sources/awesoMux/Services/AgentRuntimeEnvironment.swift:39-40` always trusts
Claude Code/Codex hook events regardless of this status probe) — it's purely
a Settings-panel display bug, but a real and confusing one.

### Task 2 background: cross-provider event contamination

Every terminal pane gets a unique hook-event file
(`AWESOMUX_AGENT_EVENT_FILE`, `Sources/AwesoMuxCore/AgentRuntimeEnvironmentKey.swift:5`)
that Claude Code/Codex/etc. hook scripts append JSONL events to. This env var
is a plain inherited process environment variable with no process-identity
scoping. Confirmed live: the Codex status plugin
(`~/Library/Application Support/awesoMux/AgentIntegrations/rendered/codex/plugins/awesomux-codex-status/hooks/hooks.json`)
registers the *same* `awesoMuxAgentHook --provider codex` command for
`SessionStart`/`Stop`/`PostToolUse`/etc. When a Claude Code session runs a Bash
tool call that invokes `codex exec` (e.g. the `codex-buddy` skill's
adversarial-review pattern) as a **child process**, that child inherits the
parent pane's `AWESOMUX_AGENT_EVENT_FILE`, and if it has its own Codex-flavored
hook config active it writes `kind: "Codex"` events into the *same* per-pane
event stream as the pane's real, top-level, interactive Claude Code session.

**Accepted residual risk — lost SessionStart hook.** The guard's escape
hatch only admits a different-kind `SessionStart` once the established
agent's own tracked lifecycle already reads stopped or ended
(`state.lifecycle.isEnded || state.lifecycle.currentIsStopped`) — it does
not pass unconditionally. A *genuine* agent switch in a pane therefore still
depends on either that SessionStart hook landing while the old agent is
between turns, or the old agent's own SessionEnd landing first. If both are
lost (the `hooks.json` command's own `timeout: 10` firing, a crash before
the hook subprocess writes) while the *old* agent's process is also still
technically alive and mid-turn, every subsequent real event from the new
agent gets rejected as contamination, and the pane sticks on the stale old
identity until something else untangles it (e.g. the old process eventually
does exit and post its own SessionEnd, which resets the pane to `.shell` and
re-opens it to any kind). This requires two independent hook deliveries to
both fail in the same pane to actually bite (old agent's own exit signal is
unaffected by this guard — same-kind events always pass) — accepted as
residual risk rather than mitigated with a time-based override, since
SessionStart delivery is reliable in practice and a timer-based escape hatch
would reopen exactly the kind of silent-identity-hijack window this fix
exists to close. Revisit if this is ever actually observed in the wild.

**Related, narrower compound case (final whole-branch review finding):** the
guard's `currentIsStopped` escape hatch is keyed on the established agent's
lifecycle reading "stopped," not on WHY it's stopped. If a user's own
blocking Stop hook (the out-of-scope scenario above) vetoes Claude's first
Stop attempt — meaning the reducer's `state.lifecycle` briefly reads
`.stopped` even though Claude is about to keep going — and a nested `codex
exec` child's own `SessionStart` lands in that exact window, the guard
allows it through and the pane flips to `.codex`. Claude's own subsequent
continuation events are then non-`SessionStart` and now foreign relative to
the pane's `.codex` identity, so they're rejected until the nested codex
process ends or Claude fires a fresh `SessionStart`. This requires two
independent mechanisms (a user-configured blocking Stop hook AND a
nested-agent invocation) to overlap in the same narrow window, so it's
accepted under the same "false negatives are fine, false positives aren't"
umbrella as the risk above — noted here rather than acted on.

Confirmed live in the event file for pane `8e3b71b1-...`
(`~/Library/Application Support/awesoMux/runtime-events/2A0759DD-....jsonl`):

```
{"execution":"waiting","kind":"Claude Code","phase":"stop", ...}
{"execution":"waiting","kind":"Codex","phase":"stop", ...}          <- contamination
{"execution":"thinking","kind":"Claude Code","phase":"promptSubmit", ...}
```

**Mechanism confirmed by direct experiment**, not just inference from the log
correlation above. Ran the real hook binary as `--provider codex` with a
live pane's `AWESOMUX_AGENT_EVENT_FILE` set, exactly reproducing what a
`codex exec` child process spawned inside that pane would do if it inherits
the pane's environment and has awesoMux's Codex status hooks active:

```sh
echo '{"hook_event_name": "Stop"}' \
  | AWESOMUX_AGENT_EVENT_FILE="<pane's event file>" \
    /Applications/awesoMux.app/Contents/MacOS/awesoMuxAgentHook --provider codex
```

This appended `{"execution":"waiting","kind":"Codex","phase":"stop","source":"codex",...}`
directly into that pane's own Claude-Code-only event stream. The causal
chain is proven, not inferred: any subprocess with awesoMux status hooks
active that inherits a pane's `AWESOMUX_AGENT_EVENT_FILE` will write into
that pane's shared stream, regardless of which provider it is.

Independent of that mechanism being exactly right in every detail, the fix
below rests on a narrower and unconditionally-true claim: an established,
non-shell pane identity should never be silently overwritten by a
mismatched-kind mid-session event absent a `SessionStart`. That's the actual
invariant being restored.

`AgentRuntimeEventReducer.decision(for:...)` (`Sources/AwesoMuxCore/Stores/AgentRuntimeEventReducer.swift:302-313`)
lets *any* event whose `kind` is non-nil freely overwrite `resolvedKind`, with
no check against the pane's already-established identity — and, worse, still
advances the pane's dedupe/staleness `lastAppliedTimestamp` watermark and can
mutate lifecycle state (including a stray Codex `SessionEnd` fully resetting
an active Claude Code pane back to `.shell`) even when the fix only guards
`resolvedKind`. The fix must reject the *entire* foreign-kind event before it
touches any pane state, not just null out the kind field.

**Explicitly out of scope for this plan:** the separate, related-looking
symptom where a *same-provider* trailing `PostToolUse`/toolEnd event (from a
legitimate Claude Code hook-forced continuation after a user's own **blocking**
Stop hook — e.g. a `stop-session-doc-check.sh` — vetoes the first Stop
attempt) can leave a pane's `agentState` at `.thinking` for up to ~60-90s
until Claude Code's own idle-prompt `Notification` hook re-confirms
`.waiting`. This was confirmed live in a *clean, single-provider* trace (no
cross-contamination) and is a separate mechanism from Task 2's bug. Loosening
`AgentPromptGate`'s `agentState == .waiting` guard to tolerate this window
was considered and rejected: `.thinking` can mean the CLI is mid-render and
genuinely unsafe to inject keystrokes into, and only a real Stop event proves
the terminal is back at a safe, receptive prompt. This is `AgentPromptGate`
working as designed (false negatives are its explicitly accepted tradeoff,
per its own doc comment) rather than a bug with a safe code fix — flag this
finding to the user rather than attempting a fix here. The lever the user
actually controls here is their own blocking Stop hook (e.g.
`stop-session-doc-check.sh`): the more aggressively it vetoes a Stop, the
longer this window gets. If the UX cost matters more than the enforcement
it buys, that hook's own strictness is the tunable, not awesoMux.

**Tradeoff decision, not just a side effect:** Task 2's fix also means a
nested `codex exec` invocation's progress (e.g. codex-buddy's adversarial
review) no longer shows up as transient "Codex"/"thinking" activity in the
host pane at all — it's dropped before reaching pane state, rather than
displayed-but-wrong as it is today. This is a deliberate choice, consistent
with `AgentPromptGate`'s stated philosophy (false negatives over false
positives): silently absent is safer than silently misleading. If nested-agent
visibility in the host pane is something the user wants later, that's a new,
separate feature (e.g. a distinct "running codex-buddy" indicator sourced
from the Bash tool call itself, not from the shared hook stream) — not a
reason to weaken this guard.

---

### Task 1: Fix `claude plugin list --json` parsing for the `id` field schema

**Files:**
- Modify: `Sources/awesoMux/Services/ProcessAgentPluginRunner+Claude.swift:382-421` (`ClaudePluginListEntry`)
- Test: `Tests/awesoMuxTests/ClaudePluginListParsingTests.swift` (create)

**Interfaces:**
- Consumes: nothing new.
- Produces: `ClaudePluginListEntry.matches(_ ref: AgentPluginMarketplaceRef) -> Bool` keeps its exact signature and call sites (`ProcessAgentPluginRunner+Claude.swift:104`, `:341`) unchanged.

- [ ] **Step 1: Write the failing test**

Create `Tests/awesoMuxTests/ClaudePluginListParsingTests.swift`:

```swift
import Testing
@testable import awesoMux

@Suite("ClaudePluginList parsing")
struct ClaudePluginListParsingTests {
    @Test("parses the current CLI's flat id field")
    func parsesFlatIDField() throws {
        let json = """
            [
              {
                "id": "awesomux-claude-status@awesomux-claude",
                "version": "0.1.0",
                "scope": "user",
                "enabled": true,
                "installPath": "/Users/x/.claude/plugins/cache/awesomux-claude/awesomux-claude-status/0.1.0",
                "installedAt": "2026-07-17T14:48:47.467Z",
                "lastUpdated": "2026-07-17T14:48:47.467Z"
              }
            ]
            """
        let entries = try ClaudePluginList.parse(json)
        #expect(entries.count == 1)
        let ref = AgentPluginMarketplaceRef(
            marketplaceName: "awesomux-claude",
            pluginName: "awesomux-claude-status"
        )
        #expect(entries[0].matches(ref))
        #expect(entries[0].enabled)
    }

    @Test("still parses the legacy split name/marketplace fields")
    func parsesLegacySplitFields() throws {
        let json = """
            [{"name": "awesomux-claude-status", "marketplace": "awesomux-claude", "enabled": true, "errors": []}]
            """
        let entries = try ClaudePluginList.parse(json)
        let ref = AgentPluginMarketplaceRef(
            marketplaceName: "awesomux-claude",
            pluginName: "awesomux-claude-status"
        )
        #expect(entries[0].matches(ref))
    }

    @Test("does not match a differently-named id")
    func rejectsMismatchedID() throws {
        let json = """
            [{"id": "some-other-plugin@some-other-marketplace", "enabled": true}]
            """
        let entries = try ClaudePluginList.parse(json)
        let ref = AgentPluginMarketplaceRef(
            marketplaceName: "awesomux-claude",
            pluginName: "awesomux-claude-status"
        )
        #expect(!entries[0].matches(ref))
    }

    @Test(
        "rejects malformed id shapes rather than guessing",
        arguments: ["", "@market", "name@", "name", "a@b@c"]
    )
    func rejectsMalformedIDShapes(id: String) throws {
        let json = "[{\"id\": \"\(id)\", \"enabled\": true}]"
        let entries = try ClaudePluginList.parse(json)
        #expect(entries[0].name == nil, "id \"\(id)\" should not parse a usable name")
    }
}
```

Cross-model review (codex-buddy) caught that `id.split(separator: "@", maxSplits: 1)`
(Swift's default `omittingEmptySubsequences: true`) mis-parses boundary
shapes: `"@market"` silently becomes `name: "market", marketplace: nil`
(wrong field gets the value), and `"name@"` becomes `name: "name",
marketplace: nil` — which `matches(_:)` then treats as "matches any
marketplace with this bare name" (`marketplace == nil || marketplace ==
ref.marketplaceName`), a false-positive risk. The fix below requires exactly
two non-empty parts and rejects (falls back to `nil`, same as today's
existing "can't parse" behavior) anything else — deny-by-default, consistent
with `AgentPromptGate`'s pattern elsewhere in this codebase.

`AgentPluginMarketplaceRef` is declared in
`Sources/awesoMux/Services/AgentPluginInstallManifest.swift:10-19` as a plain
struct (`var marketplaceName: String`, `var pluginName: String`, in that
declaration order — the synthesized memberwise initializer requires labeled
arguments in that same order) with a computed `pluginRef: String { "\(pluginName)@\(marketplaceName)" }`.

- [ ] **Step 2: Run test to verify it fails**

Run: `./script/swift-test.sh --filter ClaudePluginListParsingTests`
Expected: FAIL — `parsesFlatIDField` fails because `name` decodes to `nil` and `matches` returns `false`. (`rejectsMalformedIDShapes` passes trivially today, since `name` is always `nil` before this fix — it only becomes a meaningful regression guard once Step 3 lands.)

- [ ] **Step 3: Implement the fix**

In `Sources/awesoMux/Services/ProcessAgentPluginRunner+Claude.swift`, replace
the `ClaudePluginListEntry` struct (currently lines 382-421) with:

```swift
struct ClaudePluginListEntry: Decodable, Equatable, Sendable {
    var name: String?
    var marketplace: String?
    var enabled: Bool
    var errors: [String]

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case marketplace
        case enabled
        case errors
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Claude Code 2.1.217+ emits a flat `id: "name@marketplace"` field
        // instead of separate name/marketplace keys (verified live against
        // `claude plugin list --json`); split it so `matches(_:)` keeps
        // working unmodified. Older CLI versions may still emit the split
        // fields, so prefer them when present and fall back to splitting id.
        if let rawName = try container.decodeIfPresent(String.self, forKey: .name) {
            name = rawName
            marketplace = try container.decodeIfPresent(String.self, forKey: .marketplace)
        } else if let id = try container.decodeIfPresent(String.self, forKey: .id) {
            // Require exactly two non-empty parts — omittingEmptySubsequences:
            // false so a boundary "@" (leading/trailing/doubled) produces an
            // empty part that fails the count/isEmpty checks instead of
            // silently misassigning name/marketplace (cross-model review
            // finding: the default split() drops empty parts, so "@market"
            // was silently parsed as name="market", marketplace=nil).
            let parts = id.split(separator: "@", omittingEmptySubsequences: false)
            if parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty {
                name = String(parts[0])
                marketplace = String(parts[1])
            } else {
                name = nil
                marketplace = nil
            }
        } else {
            name = nil
            marketplace = nil
        }
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        errors = try container.decodeIfPresent([String].self, forKey: .errors) ?? []
    }

    init(name: String?, marketplace: String?, enabled: Bool, errors: [String]) {
        self.name = name
        self.marketplace = marketplace
        self.enabled = enabled
        self.errors = errors
    }

    /// Matches our plugin either by the `name@marketplace` ref or by the bare
    /// plugin name when the CLI reports name and marketplace separately.
    func matches(_ ref: AgentPluginMarketplaceRef) -> Bool {
        if let name {
            if name == ref.pluginRef { return true }
            if name == ref.pluginName {
                return marketplace == nil || marketplace == ref.marketplaceName
            }
        }
        return false
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./script/swift-test.sh --filter ClaudePluginListParsingTests`
Expected: PASS, all 4 tests (`rejectsMalformedIDShapes` runs as 5 parameterized cases).

- [ ] **Step 5: Check Codex's equivalent parser for the same bug**

`grep -n "ClaudePluginList\|struct.*PluginListEntry" Sources/awesoMux/Services/ProcessAgentPluginRunner+Codex.swift`.
If Codex's status probe has its own, differently-shaped plugin-list parser
that decodes a `name`/`marketplace`-only schema for whatever `codex` CLI
subcommand it shells out to, check (`codex <whatever list command> --json`
directly, live) whether its current CLI output still matches. If it's a
different command with a different schema that already matches reality,
leave it alone — don't fix a schema that isn't broken. Note what you found
in the commit message.

- [ ] **Step 6: Commit**

```bash
git add Sources/awesoMux/Services/ProcessAgentPluginRunner+Claude.swift Tests/awesoMuxTests/ClaudePluginListParsingTests.swift
git commit -m "fix(agent-plugins): parse claude plugin list's flat id field"
```

---

### Task 2: Reject cross-provider events from overwriting an established pane identity

**Files:**
- Modify: `Sources/AwesoMuxCore/Stores/AgentRuntimeEventReducer.swift:97-119` (`decision(for:...)`, add a guard right after the dedupe check)
- Test: `Tests/AwesoMuxCoreTests/AgentRuntimeEventReducerTests.swift` (extend)

**Interfaces:**
- Consumes: `AgentRuntimeEvent.kind: AgentKind?` (always non-nil for real hook-sourced events — set unconditionally in `AgentHookEventMapper.event(...)`, `Sources/AwesoMuxAgentHookSupport/AgentHookEventMapper.swift:26`), `AgentRuntimeEvent.phase: AgentRuntimePhase?`, `TerminalPane.agentKind: AgentKind`, and the reducer's own existing `RuntimeEventState.Lifecycle.isEnded`/`.currentIsStopped` computed properties (`AgentRuntimeEventReducer.swift:12-22`).
- Produces: `AgentRuntimeEventReducer.decision(for:currentSession:paneID:terminalIsFocused:now:) -> Decision?` keeps its exact signature; a rejected event now returns `nil` (same contract as the existing dedupe/staleness early-returns) instead of a `Decision` that nulls the kind.

- [ ] **Step 1: Write the failing test**

Add to `Tests/AwesoMuxCoreTests/AgentRuntimeEventReducerTests.swift`:

Cross-model review (codex-buddy) caught two problems with an earlier draft of
these tests and the guard they exercise, both folded in below:

1. **Broken fixture.** `decision(for:...)` is a pure function — it returns a
   `Decision`, it does not mutate `currentSession`. Calling it twice against
   the same `session` value (as an earlier draft did, to "establish" Claude
   Code via a first call) means the *second* call still sees
   `currentPane.agentKind == .shell`, so the guard's
   `currentPane.agentKind != .shell` condition is false and the contaminating
   event is wrongly let through in the test itself — the test would have
   passed for the wrong reason (or failed to actually exercise the guard).
   Fixed below by constructing the pane as already `.claudeCode` directly.
2. **The `SessionStart` escape hatch defeats the fix.** An earlier draft
   allowed *any* mismatched-kind `SessionStart` through unconditionally. But
   Task 2's own background section already established that a nested
   `codex exec` child registers hooks for `SessionStart` too (its own CLI
   startup fires one) — so that escape hatch would let the exact nested
   subprocess this fix targets take over the pane the moment it starts,
   just via a different hook phase. The fix below only trusts a
   mismatched-kind `SessionStart` once the pane's *own tracked lifecycle*
   (not just its raw `agentKind`) shows the established agent has stopped or
   ended — i.e. between turns or gone, not `.active` mid-turn. A nested
   child process's `SessionStart` fires while its *parent* Claude Code
   session is still `.active` (mid Bash-tool-call), so it's correctly
   rejected; a genuine handoff (old agent posts `Stop` or `SessionEnd`,
   *then* a new agent's `SessionStart` arrives) is correctly allowed.

```swift
@Test("a different-kind event does not overwrite an established pane identity")
func differentKindEventDoesNotOverwriteEstablishedIdentity() throws {
    // The pane is already established as Claude Code — mirrors a restored
    // session snapshot where the pane struct already carries its agent kind
    // while the reducer's own in-memory per-pane lifecycle tracking starts
    // fresh (defaults to `.active`).
    let session = TerminalSession(title: "shell", workingDirectory: "~", agentKind: .claudeCode)
    let paneID = session.activePaneID
    var reducer = AgentRuntimeEventReducer()

    // Simulate a `codex exec` subprocess (spawned as a Bash tool call inside
    // that same pane) whose inherited AWESOMUX_AGENT_EVENT_FILE routes its
    // own Codex-flavored hook events into this pane's stream (confirmed live
    // — see Task 2 background).
    let contaminatingCodexStop = AgentRuntimeEvent(
        source: .codex,
        kind: .codex,
        executionState: .waiting,
        phase: .stop,
        eventID: "codex-stop-1",
        timestamp: Date(timeIntervalSince1970: 101)
    )
    let contaminatingDecision = reducer.decision(
        for: contaminatingCodexStop, currentSession: session, paneID: paneID,
        terminalIsFocused: false, now: Date(timeIntervalSince1970: 101)
    )
    #expect(contaminatingDecision == nil)

    // A later, real Claude Code event must still apply normally afterward —
    // the rejected Codex event must not have poisoned the staleness watermark.
    let claudeThinking = AgentRuntimeEvent(
        source: .claudeCode,
        kind: .claudeCode,
        executionState: .thinking,
        phase: .promptSubmit,
        eventID: "claude-prompt-1",
        timestamp: Date(timeIntervalSince1970: 102)
    )
    let laterDecision = reducer.decision(
        for: claudeThinking, currentSession: session, paneID: paneID,
        terminalIsFocused: false, now: Date(timeIntervalSince1970: 102)
    )
    #expect(laterDecision?.update.agentExecutionState == .thinking)
}

@Test("a nested child process's own SessionStart does not take over a pane mid-turn")
func nestedSessionStartDuringActiveTurnIsRejected() throws {
    // The established Claude Code session's turn is still active (no Stop
    // has landed) when the nested `codex exec` child's OWN SessionStart
    // hook fires — this is the exact scenario Task 2's background section
    // confirmed live: Codex's rendered hooks.json registers SessionStart
    // too, so a bare "SessionStart passes unconditionally" guard would not
    // actually close the contamination hole.
    let session = TerminalSession(title: "shell", workingDirectory: "~", agentKind: .claudeCode)
    let paneID = session.activePaneID
    var reducer = AgentRuntimeEventReducer()

    let contaminatingCodexSessionStart = AgentRuntimeEvent(
        source: .codex,
        kind: .codex,
        executionState: .idle,
        phase: .sessionStart,
        eventID: "codex-nested-start-1",
        timestamp: Date(timeIntervalSince1970: 150)
    )
    let decision = reducer.decision(
        for: contaminatingCodexSessionStart, currentSession: session, paneID: paneID,
        terminalIsFocused: false, now: Date(timeIntervalSince1970: 150)
    )
    #expect(decision == nil)
}

@Test("a foreign-kind SessionEnd does not reset an established pane")
func foreignSessionEndDoesNotResetEstablishedPane() throws {
    let session = TerminalSession(title: "shell", workingDirectory: "~", agentKind: .claudeCode)
    let paneID = session.activePaneID
    var reducer = AgentRuntimeEventReducer()

    let contaminatingCodexSessionEnd = AgentRuntimeEvent(
        source: .codex,
        kind: .codex,
        executionState: .idle,
        phase: .sessionEnd,
        eventID: "codex-nested-end-1",
        timestamp: Date(timeIntervalSince1970: 160)
    )
    let decision = reducer.decision(
        for: contaminatingCodexSessionEnd, currentSession: session, paneID: paneID,
        terminalIsFocused: false, now: Date(timeIntervalSince1970: 160)
    )
    #expect(decision == nil)
}

@Test("a genuine SessionStart from a new provider switches the pane once the old agent has stopped")
func sessionStartFromNewProviderSwitchesAfterOldAgentStops() throws {
    let session = TerminalSession(title: "shell", workingDirectory: "~", agentKind: .claudeCode)
    let paneID = session.activePaneID
    var reducer = AgentRuntimeEventReducer()

    // The established Claude Code session reaches a real Stop first — it's
    // no longer mid-turn, matching what a genuine "user quit, launched a
    // different agent" sequence looks like.
    let claudeStop = AgentRuntimeEvent(
        source: .claudeCode,
        kind: .claudeCode,
        executionState: .waiting,
        phase: .stop,
        eventID: "claude-stop-2",
        timestamp: Date(timeIntervalSince1970: 200)
    )
    _ = reducer.decision(
        for: claudeStop, currentSession: session, paneID: paneID,
        terminalIsFocused: false, now: Date(timeIntervalSince1970: 200)
    )

    let codexSessionStart = AgentRuntimeEvent(
        source: .codex,
        kind: .codex,
        executionState: .idle,
        phase: .sessionStart,
        eventID: "codex-start-1",
        timestamp: Date(timeIntervalSince1970: 201)
    )
    let decision = reducer.decision(
        for: codexSessionStart, currentSession: session, paneID: paneID,
        terminalIsFocused: false, now: Date(timeIntervalSince1970: 201)
    )
    #expect(decision?.update.agentKind == .codex)
}
```

Case names verified against `Sources/AwesoMuxCore/Models/AgentState.swift`
(`AgentExecutionState.waiting`/`.thinking`/`.idle`),
`Sources/AwesoMuxCore/Models/AgentRuntimeEvent.swift`
(`AgentRuntimePhase.stop`/`.promptSubmit`/`.sessionStart`/`.sessionEnd`,
`AgentRuntimeSource.claudeCode`/`.codex`), and
`Sources/AwesoMuxCore/Models/AgentKind.swift`
(`AgentKind.claudeCode`/`.codex`) — all match exactly as used above.
`TerminalSession(title:workingDirectory:agentKind:)`'s convenience
initializer (used elsewhere in this same test file, e.g.
`futureTimestampsAreClamped`) seeds the active pane's `agentKind` directly.

- [ ] **Step 2: Run test to verify it fails**

Run: `./script/swift-test.sh --filter AgentRuntimeEventReducerTests`
Expected: FAIL on `differentKindEventDoesNotOverwriteEstablishedIdentity`,
`nestedSessionStartDuringActiveTurnIsRejected`, and
`foreignSessionEndDoesNotResetEstablishedPane` — all three currently return
a non-nil `Decision` because nothing today rejects a mismatched-kind event.
`sessionStartFromNewProviderSwitchesAfterOldAgentStops` should already pass
(today's code already lets a `SessionStart` through unconditionally) — it's
here as a regression guard for the fix, not a new-behavior test.

- [ ] **Step 3: Implement the fix**

In `Sources/AwesoMuxCore/Stores/AgentRuntimeEventReducer.swift`, in
`decision(for:currentSession:paneID:terminalIsFocused:now:)`, immediately
after the existing dedupe-key check (currently ending at line 121 with
`if let key = dedupeKey, state.recentEventIDs.contains(key) { return nil }`)
and before `if shouldDropGrokChildSessionEvent(event, state: state) { ... }`,
insert:

```swift
// A subprocess CLI invocation (e.g. `codex exec` run as a Bash tool call
// inside a Claude Code pane) inherits the pane's AWESOMUX_AGENT_EVENT_FILE
// and, if it has its own awesoMux status hooks installed, writes its own
// lifecycle events into this pane's stream (confirmed live — see Task 2
// background). A bare SessionStart is not enough to prove a genuine
// foreground handoff: a nested child process fires its own SessionStart
// too, while the pane's real established agent is still `.active`
// mid-turn. Only trust a different-kind SessionStart once the established
// agent's own tracked lifecycle shows it has stopped or fully ended — i.e.
// it's between turns or gone, not mid-turn. Everything else from a
// different provider is rejected outright, before it can touch dedupe,
// staleness, or lifecycle state for the pane's real agent.
if let eventKind = event.kind,
    currentPane.agentKind != .shell,
    currentPane.agentKind != eventKind,
    !(event.phase == .sessionStart && (state.lifecycle.isEnded || state.lifecycle.currentIsStopped))
{
    return nil
}
```

This guard needs `currentPane`, which is already bound earlier in the
function (`let currentPane = currentSession.layout.pane(id: paneID)`), and
`state`, the local per-pane tracking var bound just before the dedupe check
(`var state = stateByPaneID[paneID, default: RuntimeEventState()]`) — place
the new block after both are in scope (they already are, by the point of the
dedupe check). At this point in the function `state.lifecycle` still
reflects whatever the *last accepted* event left it as — none of the
mutating branches (`sessionEnd`/`sessionStart`/`stop` handling) have run yet
for the *current* candidate event, so this reads the established agent's
prior state, not something the current event already influenced.
`RuntimeEventState.Lifecycle.isEnded`/`.currentIsStopped` are the same
computed properties `restartsStoppedLifecycle`/`restartsEndedLifecycle`
already use a few lines below this guard for the same "is this pane between
turns or gone" question — this reuses that existing vocabulary rather than
inventing new state.

**Scope note (cross-model review):** this guard only fires when
`event.kind != nil`. A foreign-source event with `kind == nil` could in
principle still alter execution/attention state through the unrelated
`event.source.inferredAgentKind` fallback path (`AgentRuntimeEventReducer.swift:309-310`,
only reachable when `currentPane.agentKind == .shell`). That path is
structurally distinct from the contamination mechanism this task fixes:
every event the hook helper actually emits always carries a non-nil `kind`
(`AgentHookProvider.kind: AgentKind` is non-optional, and
`AgentHookEventMapper.event(...)` sets `kind: provider.kind` unconditionally
— `Sources/AwesoMuxAgentHookSupport/AgentHookEventMapper.swift:26`), so a
real hook-sourced contamination event is never `kind == nil` in practice.
Not adding speculative handling for a path the confirmed contamination
vector can't actually reach.

- [ ] **Step 4: Run test to verify it passes**

Run: `./script/swift-test.sh --filter AgentRuntimeEventReducerTests`
Expected: PASS, all four new tests plus all pre-existing tests in this file
and `AgentRuntimeEventReducerEdgeTests.swift` (run that suite too — it's a
sibling file testing the same reducer and may share fixtures/assumptions
this change could affect; codex-buddy's review confirmed no existing test in
either file exercises a mismatched-kind event against a non-shell pane, so
none should be broken by this guard — but verify directly rather than
trusting that confirmation blind).

Run: `./script/swift-test.sh --filter "AgentRuntimeEventReducerTests|AgentRuntimeEventReducerEdgeTests"`
Expected: PASS, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add Sources/AwesoMuxCore/Stores/AgentRuntimeEventReducer.swift Tests/AwesoMuxCoreTests/AgentRuntimeEventReducerTests.swift
git commit -m "fix(agent-runtime): reject cross-provider events from a different pane's agent"
```

---

### Task 3: Full verification pass

**Files:** none (verification only)

- [ ] **Step 1: Run the full test suite**

```bash
./script/swift-test.sh 2>&1 | tail -60
```

Expected: 0 new failures. `DocumentRevisionMonitorTests` may show flaky
failures under full-suite parallel load (confirmed pre-existing on this
branch's baseline, passes clean in isolation via
`./script/swift-test.sh --filter DocumentRevisionMonitorTests`) — this is not
this plan's concern; don't attempt to fix it here, but do confirm no *other*
new suite failures appeared.

- [ ] **Step 2: Run preflight**

```bash
./script/preflight.sh
```

Expected: passes (formatting/lint). If `script/format.sh` flags anything in
the two touched files, run
`script/format.sh Sources/awesoMux/Services/ProcessAgentPluginRunner+Claude.swift Sources/AwesoMuxCore/Stores/AgentRuntimeEventReducer.swift`
and inspect the diff before committing the formatting fix separately.

- [ ] **Step 3: Manual sanity check (optional but recommended given this touches live-app-observed behavior)**

If awesoMux is running with the fixed build, reopen Settings → Agents →
Claude Code and confirm "Check status" now reports "Enabled" instead of "Not
installed" (given the plugin genuinely is installed/enabled, confirmed
earlier via `claude plugin list --json`).
