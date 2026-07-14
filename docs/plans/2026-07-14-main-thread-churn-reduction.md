# Main-Thread Churn Reduction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cut the main-thread cost that makes typing and workspace switching stutter during agent streaming: a 90s live sample showed the main thread only 39% idle — ~24% of all samples in SwiftUI relayout + accessibility recompute of sidebar rows, ~5% in the visible-text agent detector's ICU string scans.

**Architecture:** Three independent reductions, in causal order. (1) Stop the highest-frequency unguarded store publish: `applyPaneUpdate` mutates `&_groups[…]` in place, so EVERY agent runtime event — including a repeat of the same execution state, which Claude Code emits continuously mid-turn — fires a whole-store `@Observable` publish; the heartbeat timestamp refresh that motivates it can be coarsened to 10s exactly like the already-blessed `agentActivityFreshnessCoarsening` fix. (2) Skip the ~59-substring-scan detector pass when a reliable-hook agent (Claude/Codex/OpenCode) has a fresh runtime event — today the scan runs and its result is provably discarded by the suppression reducer. (3) Make sidebar session rows `Equatable` so a publish only re-runs (and re-merges the accessibility node of) rows whose rendered inputs changed.

**Tech Stack:** Swift 6.3 / SwiftPM, swift-testing, Swift Observation framework.

## Global Constraints

- Conventional Commits, subject ≤72 chars, lowercase imperative.
- `./script/swift-test.sh` for tests; `./script/format.sh <changed files only>`; `./script/preflight.sh` before the PR. Check BOTH the swift-testing and XCTest summaries in test output.
- Do not weaken any quit-risk/liveness semantic: `QuitRiskPolicy.isFreshAgentExecution` compares against a 60s staleness threshold (`TerminalPane.staleAgentActivityThreshold`); a coarsened heartbeat may make staleness fire up to 10s early, which the codebase already documents as immaterial (`SessionStore.swift:266-272`). Never more than 10s.
- Do not change VoiceOver behavior: the a11y richness of sidebar rows is mandated by ADR-0006 (`docs/adr/0006-sidebar-source-list-a11y.md`); the VoiceOver value-changed announcement rides the raw visible-text diff (`GhosttySurfaceTerminalEvents.swift:419-424`) and must keep firing for every pane.
- Preserve detector fallbacks: shell panes (agent launch detection) and Pi/Grok (`usesReliableAttentionHooks == false`, `AgentKind.swift:77-98`) must keep the full text scan.

## Background for the implementer

- The publish storm: `SessionStore+Facade.swift:238-263` (`applyPaneUpdate`) calls `WorkspaceAttentionReducer.updatePane(&_groups[position.groupIndex].sessions[position.sessionIndex], …)`. Mutating through `&_groups[…]` fires the store's `@Observable` publish unconditionally — even when the reducer changed nothing but the heartbeat timestamp, and even when it changed nothing at all. `WorkspaceAttentionReducer.swift:77-97` refreshes `pane.lastAgentStateChangeAt = now` on EVERY execution-state event including same-state repeats, with an in-code comment acknowledging "the per-second re-render this causes" as a tracked follow-up.
- The blessed pattern: `SessionStore.updateShellActivity` (`SessionStore.swift:349-364`) runs its reducer on a LOCAL COPY and assigns back only on real change; `SessionStore.markAgentActivityObserved` (`:286-320`) coarsens its own heartbeat writes with `agentActivityFreshnessCoarsening = 10` (`:272`).
- `TerminalPane.==` (`Models/TerminalPane.swift:266-282`) deliberately EXCLUDES `lastAgentStateChangeAt`, `shellActivity`, `needsTerminalQuitConfirmation`, `foregroundProcessLiveness`, `remoteConnectionHealth` — so session-value equality CANNOT be used to detect "did the reducer mutate anything": a timestamp-only refresh would compare equal and never be written back, silently breaking quit-risk liveness. The reducer must report mutation explicitly.
- The detector: `GhosttySurfaceTerminalEvents.swift:394-453` (`sampleAgentStateFromVisibleText`) reads the full viewport (cheap, a few KB) then runs `AgentOutputDetector.detectedOutput` (`Models/AgentOutputDetector.swift:27-94`) — worst case ~59 `contains` scans plus a full ICU `.folding(.caseInsensitive, .diacriticInsensitive).lowercased()` pass, and it derives agent identity TWICE (once at line 50 for `stateCueAgentKind`, again at line 84 for the `.waiting` fallback). Suppression that discards the result happens AFTER the scan (`:439-451`, `VisibleTextAgentStateReducer.swift:71-96` with `runtimeEventSuppressionWindow = 2.0s`).
- Sidebar rows: `SidebarSessionTile` (`Views/SidebarSessionTile.swift:7-40+`) is not `Equatable`; each row applies `.accessibilityElement(children: .combine)` plus 7-11 accessibility actions, all re-merged whenever `SidebarView.body` re-runs — which is every store publish, because `SidebarView` reads `sessionStore.groups` wholesale. `TerminalPane.==`'s comment says: "Revisit if a view ever takes a `TerminalPane` as an `Equatable` render trigger" — Task 3 is that revisit, and because `shellActivity` is excluded from pane equality, the row's `==` must compare RENDERED PROJECTIONS (`effectiveChromeState`) rather than raw pane equality.

---

### Task 1: Gate the publish — mutation-reporting reducer + coarsened heartbeat

**Files:**
- Modify: `Sources/AwesoMuxCore/Stores/WorkspaceAttentionReducer.swift:40-130` (`updatePane`)
- Modify: `Sources/AwesoMuxCore/Stores/SessionStore+Facade.swift:238-263` (`applyPaneUpdate`)
- Test: locate the existing reducer suite with `grep -rln "WorkspaceAttentionReducer" Tests/` and extend it (create `Tests/AwesoMuxCoreTests/WorkspaceAttentionReducerHeartbeatTests.swift` if none covers `updatePane`).

**Interfaces:**
- Produces: `WorkspaceAttentionReducer.updatePane(_:paneID:update:now:)` return type changes from `UnreadChange?` to `PaneUpdateOutcome`:

```swift
struct PaneUpdateOutcome {
    var unreadChange: UnreadChange?
    /// True when any field of the session or its panes was written —
    /// including a due heartbeat refresh. False means the caller must not
    /// touch `_groups` (no @Observable publish) and may skip risk
    /// reclassification.
    var didMutate: Bool
}
```

- All other `updatePane` callers found by `grep -rn "WorkspaceAttentionReducer.updatePane" Sources/` must be updated to the new return type in this task.

- [ ] **Step 0: Audit every write site first**

Before writing tests, enumerate ALL mutations in `WorkspaceAttentionReducer.updatePane` with `grep -n "pane\.\|session\." Sources/AwesoMuxCore/Stores/WorkspaceAttentionReducer.swift` — there are at least THREE `lastAgentStateChangeAt` writes (`:88`, `:96`, `:222`) plus `agentKind` (`:73`), `title`, `workingDirectory`, `attentionReason`, and unread-count writes. Every assignment must feed `didMutate`. Also trace `SessionStore.applyAgentRuntimeEvent` end-to-end and confirm ALL of its `_groups` writes route through the gated `applyPaneUpdate` — if it has a second direct `&_groups` write, gate that too or stop and flag it.

- [ ] **Step 1: Write the failing tests**

```swift
@Suite("WorkspaceAttentionReducer heartbeat coarsening")
struct WorkspaceAttentionReducerHeartbeatTests {
    // Build a session with one pane whose lastAgentStateChangeAt = t0 and
    // agentExecutionState = .thinking, using the shared test fixtures
    // (see Tests/TestSupport — the deterministic toolkit).

    @Test("same-state repeat within the coarsening window mutates nothing")
    func sameStateRepeatIsQuiet() {
        // update: SessionUpdate(agentExecutionState: .thinking)
        // now: t0 + 1s
        // #expect(outcome.didMutate == false)
        // #expect(pane.lastAgentStateChangeAt == t0)
    }

    @Test("same-state repeat past the window refreshes the heartbeat")
    func sameStateRepeatRefreshesWhenDue() {
        // now: t0 + 11s  (> SessionStore.agentActivityFreshnessCoarsening)
        // #expect(outcome.didMutate == true)
        // #expect(pane.lastAgentStateChangeAt == t0 + 11s)
    }

    @Test("a state CHANGE refreshes immediately regardless of the window")
    func stateChangeAlwaysRefreshes() {
        // update: .output at t0 + 1s
        // #expect(outcome.didMutate == true)
        // #expect(pane.agentExecutionState == .output)
        // #expect(pane.lastAgentStateChangeAt == t0 + 1s)
    }

    @Test("an agent-kind-only correction reports mutation")
    func agentKindOnlyCorrectionMutates() {
        // update: SessionUpdate(agentKind: .claudeCode) on a .codex pane,
        // no execution state. VisibleTextAgentStateReducer can emit exactly
        // this (kind correction with shouldApplyState == false) — dropping
        // it would strand a mistagged pane forever.
        // #expect(outcome.didMutate == true)
        // #expect(pane.agentKind == .claudeCode)
    }

    @Test("title/attention/unread writes still report mutation")
    func fieldWritesReportMutation() {
        // update: SessionUpdate(title: "new") → didMutate == true
    }

    @Test("quit-risk staleness boundary survives worst-case coarsening phase")
    func stalenessBoundaryWithCoarsening() {
        // Worst case: heartbeat refreshed at t0, repeats arrive but stay
        // sub-window until t0+9.999s (no refresh), then silence.
        // QuitRiskPolicy.isFreshAgentExecution(at: t0 + 9.999 + 59.999) must
        // read freshness from the LAST WRITTEN stamp: verify risk is still
        // true at stamp+59.999s and false at stamp+60s — i.e. the coarsening
        // shifts the anchor by at most agentActivityFreshnessCoarsening and
        // never widens the 60s trust window.
    }
}
```

Fill the bodies with the suite's real fixture helpers — every `#expect` above is the required assertion.

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/edequalsawesome/Development/awesomux-worktrees/debug-stutter-close-warning && ./script/swift-test.sh --filter WorkspaceAttentionReducerHeartbeat 2>&1 | tail -15`
Expected: compile FAILURE (`PaneUpdateOutcome` not defined) or assertion failures.

- [ ] **Step 3: Implement the reducer change**

In `WorkspaceAttentionReducer.updatePane`, track mutation explicitly and coarsen the heartbeat. The execution-state block (`:77-89`) becomes:

```swift
if let agentExecutionState = update.agentExecutionState {
    if agentExecutionState != pane.agentExecutionState {
        pane.agentExecutionState = agentExecutionState
        pane.lastAgentStateChangeAt = now
        didMutate = true
    } else if now.timeIntervalSince(pane.lastAgentStateChangeAt)
        >= SessionStore.agentActivityFreshnessCoarsening
    {
        // Same-state repeat ("still thinking"): the timestamp doubles as the
        // liveness heartbeat isQuitRisk() reads, so it must still refresh —
        // but coarsened to the same 10s grain as markAgentActivityObserved,
        // which the 60s staleness threshold already tolerates. Sub-window
        // repeats mutate nothing, so they no longer publish the store.
        pane.lastAgentStateChangeAt = now
        didMutate = true
    }
}
```

Apply the same shape to the `update.agentState` block (`:91-97`): `applyLegacyAgentState` (`Models/TerminalPane.swift:152-165`) mutates EXACTLY `agentExecutionState` and (conditionally) `attentionReason` — nothing else. Snapshot those two fields before the call, compare after; set `didMutate = true` and refresh the timestamp only when one changed OR the coarsening window elapsed. Do NOT use `TerminalPane.==` (it excludes the runtime fields; see Background) and do NOT compare fields the function never touches.

Every other assignment found in Step 0's audit (`agentKind` at `:73`, title, workingDirectory, attentionReason at `:99-112`, unread counts, and the third timestamp write at `:222`) sets `didMutate = true` — but ONLY when the written value differs from the current one (a same-value title re-emit must stay quiet; that is the point of the gate). Prefer marking mutation at each actual assignment over a post-hoc checklist. Return `PaneUpdateOutcome(unreadChange: <existing value>, didMutate: didMutate)`.

- [ ] **Step 4: Implement the store-side gate**

`applyPaneUpdate` (`SessionStore+Facade.swift:238-263`) runs the reducer on a local copy and writes back only on mutation:

```swift
private func applyPaneUpdate(
    sessionID: TerminalSession.ID,
    paneID: TerminalPane.ID?,
    update: WorkspaceAttentionReducer.SessionUpdate,
    now: Date = Date()
) -> Bool {
    guard let position = position(for: sessionID),
        let targetPaneID = resolvedPaneID(sessionID: sessionID, paneID: paneID)
    else {
        return false
    }
    // Local copy first: mutating through `&_groups[…]` fires the whole-store
    // @Observable publish even when the reducer changes nothing (INT-523
    // family — same fix as updateShellActivity).
    var session = _groups[position.groupIndex].sessions[position.sessionIndex]
    let outcome = WorkspaceAttentionReducer.updatePane(
        &session,
        paneID: targetPaneID,
        update: update,
        now: now
    )
    // Quiet same-state repeat: return true (the event WAS accepted — callers
    // key suppression bookkeeping and announcement diffs on this Bool, and a
    // false here would un-arm the visible-text detector suppression), but do
    // not touch _groups and skip the commit.
    guard outcome.didMutate else { return true }
    _groups[position.groupIndex].sessions[position.sessionIndex] = session
    commit(
        WorkspaceMutationEffect(
            unreadChange: outcome.unreadChange,
            riskSessionIDs: [sessionID]
        ),
        now: now
    )
    return true
}
```

Update every other `WorkspaceAttentionReducer.updatePane` caller (`grep -rn "WorkspaceAttentionReducer.updatePane" Sources/`) to the new return type with the same local-copy + didMutate-gate shape.

- [ ] **Step 5: Run the full suite**

Run: `./script/swift-test.sh 2>&1 | tail -30`
Expected: PASS on both summaries. Pay attention to quit-risk and attention-reducer suites — they exercise the mutated paths.

- [ ] **Step 6: Commit**

```bash
git add Sources/AwesoMuxCore/Stores/WorkspaceAttentionReducer.swift Sources/AwesoMuxCore/Stores/SessionStore+Facade.swift Tests/
git commit -m "perf(store): gate pane-update publishes and coarsen the agent heartbeat"
```

---

### Task 2: Skip the detector scan when reliable hooks are fresh; derive identity once

**Files:**
- Modify: `Sources/AwesoMuxCore/Models/VisibleTextAgentStateReducer.swift` (new pure gate function)
- Modify: `Sources/awesoMux/Views/GhosttySurface/GhosttySurfaceTerminalEvents.swift:394-453` (`sampleAgentStateFromVisibleText`)
- Modify: `Sources/AwesoMuxCore/Models/AgentOutputDetector.swift:27-94` (single identity derivation)
- Test: the existing `VisibleTextAgentStateReducer` and `AgentOutputDetector` suites (locate with `grep -rln "AgentOutputDetector\|VisibleTextAgentStateReducer" Tests/`)

**Interfaces:**
- Produces: `VisibleTextAgentStateReducer.shouldRunVisibleTextDetector(now: TimeInterval, lastRuntimeEventAppliedAt: TimeInterval?, liveAgentKind: AgentKind) -> Bool` — pure, unit-tested. Returns `false` only when `lastRuntimeEventAppliedAt` is within `runtimeEventSuppressionWindow` AND `liveAgentKind.usesReliableHooks && liveAgentKind.usesReliableAttentionHooks`.

- [ ] **Step 1: Write the failing tests**

```swift
@Suite("Visible-text detector run gate")
struct VisibleTextDetectorRunGateTests {
    @Test("fresh runtime event + reliable-hook kind skips the scan")
    func skipsForFreshReliableHooks() {
        // liveAgentKind: .claudeCode (usesReliableAttentionHooks == true)
        // lastRuntimeEventAppliedAt: now - 1.0
        // #expect(shouldRun == false)
    }

    @Test("stale runtime event runs the scan")
    func runsWhenEventIsStale() {
        // lastRuntimeEventAppliedAt: now - 3.0 (> runtimeEventSuppressionWindow)
        // #expect(shouldRun == true)
    }

    @Test("Pi and Grok always run the scan (unreliable attention hooks)")
    func runsForUnreliableHookKinds() {
        // liveAgentKind: .grok / .pi, lastRuntimeEventAppliedAt: now - 0.5
        // #expect(shouldRun == true)
    }

    @Test("shell panes always run the scan")
    func runsForShell() {
        // liveAgentKind: .shell, lastRuntimeEventAppliedAt: nil
        // #expect(shouldRun == true)
    }
}
```

Use the real `AgentKind` case names from `Sources/AwesoMuxCore/Models/AgentKind.swift`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `./script/swift-test.sh --filter VisibleTextDetectorRunGate 2>&1 | tail -10`
Expected: compile FAILURE — function doesn't exist.

- [ ] **Step 3: Implement the gate**

In `VisibleTextAgentStateReducer`, alongside `runtimeEventSuppressionWindow`:

```swift
/// Whether sampleAgentStateFromVisibleText should run the (expensive)
/// AgentOutputDetector scan at all. When a reliable-hook agent has a fresh
/// runtime event, shouldSuppressVisibleTextState would discard any non-
/// attention result AND blockedByReliableHook discards `.needsAttention`
/// too — so the ~59-substring scan is provably wasted work. The raw
/// visible-text READ and diff still run for every pane: VoiceOver's
/// value-changed announcement and quit-risk activity marking ride that diff.
static func shouldRunVisibleTextDetector(
    now: TimeInterval,
    lastRuntimeEventAppliedAt: TimeInterval?,
    liveAgentKind: AgentKind
) -> Bool {
    guard liveAgentKind.usesReliableHooks,
        liveAgentKind.usesReliableAttentionHooks,
        let lastRuntimeEventAppliedAt
    else {
        return true
    }
    return now - lastRuntimeEventAppliedAt >= runtimeEventSuppressionWindow
}
```

In `sampleAgentStateFromVisibleText` (`GhosttySurfaceTerminalEvents.swift`), after the `markAgentActivityObserved` block (`:435-437`) and BEFORE the `detectedOutput` call (`:439-446`), insert:

```swift
let liveKindForGate = sessionStore.session(id: sessionID)?
    .layout.pane(id: paneID)?.agentKind ?? .shell
guard VisibleTextAgentStateReducer.shouldRunVisibleTextDetector(
    now: now,
    lastRuntimeEventAppliedAt: lastRuntimeEventAppliedAt,
    liveAgentKind: liveKindForGate
) else {
    return
}
```

(`lastRuntimeEventAppliedAt` already exists on the view — it's what `shouldSuppressVisibleTextState` consumes at `:455-466`; match its exact type.)

- [ ] **Step 4: Derive identity once in detectedOutput**

In `AgentOutputDetector.detectedOutput` (`:27-94`): the normalized text's agent identity is currently derived at line 50 (`stateCueAgentKind`) and AGAIN at line 84 for the `.waiting` fallback (including a redundant second Grok scan). Hoist a single `let inferredKind = inferredAgentKind(in: normalized)` above the first use and reuse it at both sites. Pure refactor — zero behavior change; the existing `AgentOutputDetector` test suite is the regression net.

- [ ] **Step 5: Run the affected suites, then the full suite**

Run: `./script/swift-test.sh --filter 'AgentOutputDetector|VisibleText' 2>&1 | tail -15` then `./script/swift-test.sh 2>&1 | tail -30`
Expected: PASS on both summaries.

- [ ] **Step 6: Commit**

```bash
git add Sources/AwesoMuxCore/Models/VisibleTextAgentStateReducer.swift Sources/AwesoMuxCore/Models/AgentOutputDetector.swift Sources/awesoMux/Views/GhosttySurface/GhosttySurfaceTerminalEvents.swift Tests/
git commit -m "perf(detector): gate visible-text scans on hook freshness, derive identity once"
```

---

### Task 3: Equatable sidebar session rows

**Files:**
- Modify: `Sources/awesoMux/Views/SidebarSessionTile.swift` (add `Equatable` via an explicit render key)
- Modify: `Sources/awesoMux/Views/SidebarGroupView.swift:188-200` and `Sources/awesoMux/Views/SidebarPinnedSectionView.swift:127-140` (apply `.equatable()` at the tile call sites)
- Test: create `Tests/awesoMuxTests/SidebarSessionTileEquatableTests.swift`

**Interfaces:**
- Consumes: `TerminalPane.effectiveChromeState` (`Models/TerminalPane.swift:182-205`) — the rendered projection that folds `shellActivity`, which raw `TerminalPane.==` excludes.
- Produces: `SidebarSessionTile: Equatable` where `==` compares `renderKey` (all non-closure rendered inputs); call sites gain `.equatable()`.

- [ ] **Step 1: Build the render key**

Read `SidebarSessionTile.swift` fully first and enumerate EVERY stored property. The invariant: **every non-closure stored property must be represented in the key; no closure may be.** Add:

```swift
extension SidebarSessionTile: Equatable {
    /// Everything the row renders, as one comparable value. TerminalPane.==
    /// deliberately excludes runtime fields (shellActivity et al) whose
    /// chrome renders through projections, so sessions are compared through
    /// the SAME projections the body reads — effectiveChromeState — never
    /// raw pane equality (see the TerminalPane equality doc comment: this
    /// is the "revisit" it names).
    private struct RenderKey: Equatable {
        let sessionID: TerminalSession.ID
        let title: String
        let workingDirectory: String?
        let notificationsMuted: Bool     // rendered as glyph, context-menu verb, AND VoiceOver label
        let activePaneID: TerminalPane.ID?  // pane-jump accessibility actions + location derivation key on it
        let paneChrome: [PaneChromeKey]
        let match: SessionMatch?
        let tint: ProjectTint
        let isActive: Bool
        let displayMode: SidebarWidthMode
        let isKeyboardFocused: Bool
        let jumpIndex: Int?
        let hasBackgroundedFloatingWork: Bool
        let isPromotedInsertion: Bool
        let isPromotionPulseActive: Bool
        let isFiltering: Bool
        let duplicateDisambiguation: SidebarDuplicateDisambiguation?
        let indexInGroup: Int
        let sessionCountInGroup: Int
        let ownerGroupIndex: Int
        let previousNeighborGroup: NeighborKey?
        let nextNeighborGroup: NeighborKey?
        let otherGroups: [NeighborKey]
        let verticalPadding: CGFloat
        let canMakeWorkspaceManaged: Bool
        // …plus a field for EVERY remaining non-closure stored property
        // found in Step 1's enumeration (extend this struct; do not skip any).
        // In the SAME commit, paste the struct's full stored-property list
        // (from the enumeration) into the test file as a doc comment so the
        // reviewer can diff key fields against stored properties mechanically.
    }

    private struct PaneChromeKey: Equatable {
        let id: TerminalPane.ID          // array ORDER matters: pane reorder must compare unequal
        let chromeState: AgentState      // pane.effectiveChromeState — folds shellActivity, which raw pane == excludes
        let unread: Int
        let attentionReason: AttentionReason?
        let progressReport: TerminalProgressReport?
        let title: String
        let remoteHost: String?          // sidebarLocation derives from the active pane's remoteHost/cwd
        let workingDirectory: String?
    }

    private struct NeighborKey: Equatable {
        let id: SessionGroup.ID
        let name: String
    }

    static func == (lhs: SidebarSessionTile, rhs: SidebarSessionTile) -> Bool {
        lhs.renderKey == rhs.renderKey
    }
}
```

`renderKey` is a computed property assembling the above from `session.panes` (chrome via `$0.effectiveChromeState`) and the stored scalars. Use the real type names from the file (e.g. if `AttentionReason`/`AgentState` differ, match them).

- [ ] **Step 2: Write the equality tests**

```swift
@Suite("SidebarSessionTile render-key equality")
struct SidebarSessionTileEquatableTests {
    // Fixture: build two tiles from the same session value with no-op closures.

    @Test("timestamp-only difference compares equal")
    func heartbeatOnlyChangeIsEqual() {
        // session B = session A with one pane's lastAgentStateChangeAt shifted
        // #expect(tileA == tileB)
    }

    @Test("shellActivity difference compares NOT equal")
    func shellActivityChangeRerenders() {
        // session B = session A with one pane's shellActivity flipped to .busy
        // (raw TerminalPane.== would call these equal — the render key must not)
        // #expect(tileA != tileB)
    }

    @Test("progress report difference compares NOT equal")
    func progressChangeRerenders() {
        // #expect(tileA != tileB)
    }

    @Test("mute toggle compares NOT equal")
    func muteChangeRerenders() {
        // session B = A with notificationsMuted flipped → tileA != tileB
    }

    @Test("active-pane change compares NOT equal")
    func activePaneChangeRerenders() {
        // session B = A with activePaneID pointing at the other pane → !=
    }

    @Test("pane reorder compares NOT equal")
    func paneReorderRerenders() {
        // session B = A with two panes swapped in layout order → !=
    }

    @Test("active pane remoteHost / cwd change compares NOT equal")
    func locationChangeRerenders() {
        // remoteHost set on the active pane → != ; cwd change → !=
    }

    @Test("unrelated other-group rename compares NOT equal (menu content)")
    func otherGroupRenameRerenders() {
        // otherGroups name change → != (move-to-group menu shows names)
    }
}
```

- [ ] **Step 3: Run tests to verify they fail, implement, re-run**

Run: `./script/swift-test.sh --filter SidebarSessionTileEquatable 2>&1 | tail -10`
Expected first: compile FAILURE (no Equatable conformance); after implementing Step 1: PASS.

- [ ] **Step 4: Apply at the call sites**

In `SidebarGroupView.swift` (`ForEach` at `:188`) and `SidebarPinnedSectionView.swift` (`:127`), wrap the tile construction's result with `.equatable()`:

```swift
SidebarSessionTile(
    /* existing arguments unchanged */
)
.equatable()
```

Closures passed to the tile MUST be stable non-capturing or capture-only-stable references where possible; since `==` ignores closures this only matters for correctness of the actions themselves, not equality — leave the existing closures as-is.

- [ ] **Step 5: Full suite + live smoke**

Run: `./script/swift-test.sh 2>&1 | tail -30` — PASS on both summaries.
Live smoke (`./script/build_and_run.sh`): with one Claude pane streaming, confirm (a) its own sidebar row updates chrome (thinking/output states, progress), (b) OTHER rows' hover/selection still work, (c) shell busy/idle dots still flip when running `sleep 3` in a shell workspace, (d) VoiceOver row labels still read the full combined description (⌥F5 quick check).

- [ ] **Step 6: Commit**

```bash
git add Sources/awesoMux/Views/SidebarSessionTile.swift Sources/awesoMux/Views/SidebarGroupView.swift Sources/awesoMux/Views/SidebarPinnedSectionView.swift Tests/awesoMuxTests/SidebarSessionTileEquatableTests.swift
git commit -m "perf(sidebar): equatable session rows via explicit render key"
```

---

### Task 4: Verification — before/after sample

**Files:** none (measurement only).

- [ ] **Step 1: Rebuild and relaunch the dev app**

Run: `./script/build_and_run.sh` (fresh binary — never trust a repro/verify on a stale build).

- [ ] **Step 2: Reproduce the workload and sample**

With at least one agent streaming output and ~6 workspaces open:

```bash
sample awesoMux 30 2 -file /tmp/awesomux-after.txt && grep -cE "AccessibilityViewGraph.needsUpdate|AccessibilityProperties.merge" /tmp/awesomux-after.txt
```

Expected: the accessibility-recompute and `NSHostingView.layout` sample counts drop by an order of magnitude vs the baseline (baseline: ~1000 a11y samples, main thread 61% busy over 90s). Record the numbers in the PR body.

- [ ] **Step 3: Preflight**

Run: `./script/preflight.sh 2>&1 | tail -15`
Expected: pass (issue #24 mapfile noise excepted).
