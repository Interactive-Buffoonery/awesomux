# ⌘W Last Pane Closes Workspace Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** ⌘W on a single-pane workspace closes the workspace (soft close, reopenable via ⇧⌘T) instead of silently restarting the shell, matching the mac-standard ⌘W mental model — with every visible command title following the new semantics.

**Architecture:** `closeActivePaneOrWindow()` → `closeActivePane()` (`Sources/awesoMux/App/AwesoMuxApp.swift:2032-2078, 2108-2151`) currently consults `DestructivePaneActionConfirmationPolicy.decision`, which maps `isSinglePane → .restartShell` (surface recycle). Change: `closeActivePane()` routes single-pane sessions to the existing `closeWorkspace(_:)` funnel (`AwesoMuxApp.swift:992-1021` — same path as the sidebar X: confirm gate, floating-slot eviction, surface discard, recently-closed capture, VoiceOver announcement) BEFORE consulting the pane policy. The policy drops its now-unreachable single-pane mapping **in the same commit** (routing + policy must land atomically — separately, single-pane ⌘W would transiently dead-end). `Action.restartShell` stays — the explicit Restart Shell command still uses it via `confirmDestructivePaneActionIfNeeded` (`AwesoMuxApp.swift:1470`). Visible command titles ("Close Pane" in the Workspace menu at `:696`, `closeShortcutTitle` at `:1992`, the palette command at `PaletteCommand.swift:340`) become single-pane-aware so no surface says "Close Pane" while closing the workspace (cross-model review finding #5).

**Tech Stack:** Swift 6.3 / SwiftPM, swift-testing.

## Global Constraints

- Conventional Commits, subject ≤72 chars, lowercase imperative.
- Run `./script/swift-test.sh` for tests; `./script/format.sh <changed files>` before committing; `./script/preflight.sh` before the PR. Check BOTH test summaries.
- User-facing copy: menu/palette titles here are plain strings today (verify against the neighboring code when editing — if any is `String(localized:)`, keep literal-as-key style per ADR-0014).
- Do not rename or rebind any shortcut — only the last-pane behavior and dependent titles change.
- Routing change and policy change land in ONE commit (atomicity constraint above).

## Background for the implementer

- `closeWorkspace(_ session:)` is `@MainActor private` on the same type as `closeActivePane()`; it re-fetches the live session by ID, runs `confirmCloseIfNeeded`, and performs the full teardown. Calling it directly is the whole routing fix.
- `DestructivePaneActionConfirmationPolicy.decision` (`Sources/awesoMux/Services/DestructivePaneActionConfirmationPolicy.swift:47-66`) has exactly one caller: `closeActivePane()` (`AwesoMuxApp.swift:2116`) — verified 2026-07-14, re-verify with `grep -rn "DestructivePaneActionConfirmationPolicy.decision" Sources/`. If a second caller appeared, stop and reassess.
- Existing tests: `Tests/awesoMuxTests/DestructivePaneActionConfirmationPolicyTests.swift`.

---

### Task 1: Route single-pane ⌘W to the workspace-close funnel (routing + policy, atomic)

**Files:**
- Modify: `Sources/awesoMux/App/AwesoMuxApp.swift:2108-2151` (`closeActivePane()`)
- Modify: `Sources/awesoMux/Services/DestructivePaneActionConfirmationPolicy.swift:47-66`
- Test: `Tests/awesoMuxTests/DestructivePaneActionConfirmationPolicyTests.swift`

**Interfaces:**
- Consumes: `closeWorkspace(_ session: TerminalSession)` (`AwesoMuxApp.swift:992`).
- Produces: `decision(session:workspaces:now:)` returns `.closePane`-flavored decisions for multi-pane sessions and `.unavailable` for single-pane sessions (single-pane is routed to workspace close by the caller before the policy runs). Signature unchanged. `Action.restartShell` case remains for the explicit restart command.

- [ ] **Step 1: Update the policy tests to the new contract**

Read `Tests/awesoMuxTests/DestructivePaneActionConfirmationPolicyTests.swift` first. Rewrite the single-pane cases: wherever a single-pane session currently expects `.proceedWithoutPrompt(.restartShell)` / `.prompt(.restartShell)`, the expectation becomes `.unavailable`, with a comment naming the caller-routes-to-closeWorkspace contract. Multi-pane expectations stay untouched.

- [ ] **Step 2: Run tests to verify the changed ones fail**

Run: `cd /Users/edequalsawesome/Development/awesomux-worktrees/debug-stutter-close-warning && ./script/swift-test.sh --filter DestructivePaneActionConfirmationPolicyTests 2>&1 | tail -15`
Expected: FAIL — single-pane cases still return restartShell decisions.

- [ ] **Step 3: Implement BOTH halves**

(a) Policy — in `decision(session:workspaces:now:)`:

```swift
static func decision(
    session: TerminalSession?,
    workspaces: WorkspaceConfig,
    now: Date = Date()
) -> Decision {
    guard let session, let activePane = session.activePane else {
        return .unavailable
    }

    // Single-pane ⌘W is a workspace close, not a pane action — the caller
    // (closeActivePane) routes it to closeWorkspace(_:) before consulting
    // this policy. Landed atomically with that routing; if you are reading
    // this without the closeActivePane early-branch, something reverted.
    guard !session.layout.isSinglePane else {
        return .unavailable
    }

    let action: Action = .closePane
    guard activePane.isQuitRisk(at: now) else {
        return .proceedWithoutPrompt(action)
    }
    guard workspaces.confirmDestructivePaneActionWithRunningAgent else {
        return .proceedWithoutPrompt(action)
    }
    return .prompt(action)
}
```

(b) Routing — at the top of `closeActivePane()` (after the `session` fetch at `:2112`):

```swift
// Last pane = the workspace: route through the same soft-close funnel as
// the sidebar X (confirm gate, floating-slot eviction, recently-closed
// capture) instead of recycling the shell in place. ⇧⌘T reopens.
if session.layout.isSinglePane {
    closeWorkspace(session)
    return
}
```

Then delete the now-dead `.restartShell` arm of the `switch action` at `:2136-2150`. If the compiler requires exhaustiveness over `Action`, keep `case .restartShell: assertionFailure("single-pane routes to closeWorkspace before the pane policy")`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `./script/swift-test.sh --filter DestructivePaneActionConfirmationPolicyTests 2>&1 | tail -15`
Expected: PASS.

- [ ] **Step 5: Commit (one commit — routing + policy)**

```bash
git add Sources/awesoMux/App/AwesoMuxApp.swift Sources/awesoMux/Services/DestructivePaneActionConfirmationPolicy.swift Tests/awesoMuxTests/DestructivePaneActionConfirmationPolicyTests.swift
git commit -m "feat(app): close the workspace when cmd-w hits the last pane"
```

---

### Task 2: Make every visible command title follow the semantics

**Files:**
- Modify: `Sources/awesoMux/App/AwesoMuxApp.swift:696` (Workspace-menu `Button("Close Pane")`), `:1990-1994` (`closeShortcutTitle`)
- Modify: `Sources/awesoMux/Services/PaletteCommand.swift:340` (palette command title)
- Modify: `Sources/awesoMux/Services/KeyboardShortcutCatalog.swift:613` (cheatsheet detail copy)

**Interfaces:**
- Consumes: `sessionStore.selectedSession?.layout.isSinglePane` at each title site.

- [ ] **Step 1: Implement title logic**

`closeShortcutTitle` (`:1990-1994`) becomes three-way:

```swift
private var closeShortcutTitle: String {
    guard let selected = sessionStore.selectedSession else { return "Close Window" }
    return selected.layout.isSinglePane ? "Close Workspace" : "Close Pane"
}
```

The Workspace-menu button at `:696` uses the same conditional title (reuse `closeShortcutTitle` if the menu site can reach it; otherwise inline the same expression). For `PaletteCommand.swift:340`, read the construction site first: if the palette command is built with access to the selected session, make the title conditional the same way; if the registry is static, retitle neutrally to "Close Pane or Workspace" and note why in the code comment. Match each site's existing localization style exactly.

`KeyboardShortcutCatalog.swift:613`:

```swift
KeyboardShortcutEntry(closePane, detail: "Close the active pane; closes the workspace when it's the last pane"),
```

- [ ] **Step 2: Full suite**

Run: `./script/swift-test.sh 2>&1 | tail -30`
Expected: PASS on both summaries.

- [ ] **Step 3: Live smoke**

Build and run (`./script/build_and_run.sh`):
1. Multi-pane workspace: File menu shows "Close Pane"; ⌘W closes the active pane only.
2. Single-pane workspace: File menu + Workspace menu show "Close Workspace"; ⌘W closes the workspace (confirm dialog only when activity is at risk); ⇧⌘T reopens it.
3. No workspace selected: title reads "Close Window".
4. Explicit Restart Shell (command palette) still restarts with its own confirm.

- [ ] **Step 4: Commit**

```bash
git add Sources/awesoMux/App/AwesoMuxApp.swift Sources/awesoMux/Services/PaletteCommand.swift Sources/awesoMux/Services/KeyboardShortcutCatalog.swift
git commit -m "feat(app): retitle close commands to match last-pane semantics"
```

- [ ] **Step 5: Preflight**

Run: `./script/preflight.sh 2>&1 | tail -15`
Expected: pass (issue #24 mapfile noise excepted).
