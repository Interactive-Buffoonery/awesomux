# Wakeup Coalescer Removal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove `GhosttyWakeupCoalescer`'s batching so every libghostty wakeup schedules its own tick immediately (matching stock Ghostty's macOS reference integration), and add a debug-level log line — shipped *first*, against the current coalescing code — so tick cadence has a before/after baseline instead of only an after.

**Architecture:** `GhosttyRuntime.wakeup(_:)` (`Sources/awesoMux/Services/GhosttyRuntimeCallbacks.swift`) is the single call site where every libghostty `wakeup_cb` invocation currently routes through an app-wide latch (`GhosttyWakeupCoalescer`) before scheduling `GhosttyRuntime.tick()`. This plan first adds a `Logger.debug` call inside `tick()` (`Sources/awesoMux/Services/GhosttyRuntime.swift`) reporting elapsed time since the previous tick, so cadence under the *current* coalesced behavior can be observed — then deletes the latch and its backing class so `wakeup(_:)` unconditionally schedules one `Task { @MainActor in runtime.tick() }` per callback, giving an after-state to compare against.

**Tech Stack:** Swift 6 strict concurrency (`@MainActor`-isolated `GhosttyRuntime`), `os.Logger`, Swift Testing (`@Test`/`#expect`).

## Provenance note (architecture review findings folded in)

This plan's task order and framing were revised after an architecture review of the original draft (see `git log` for the prior version if needed). The review's core finding: the causal claim "coalescing → bigger completion batches → more likely to trip libxev#122" is a **plausible, evidence-consistent hypothesis, not a confirmed mechanism** — the upstream bug report describes a leftover-unflushed-changes condition tied to `.no_wait` semantics, which could equally be sensitive to *call frequency* as to *batch size*, and neither this plan nor the spec it descends from runs an experiment that distinguishes the two. The reordering below (logging before removal) exists specifically to capture a baseline instead of shipping the removal with no way to compare. Task 2 also gained a stress-test smoke step and a softer commit message, per the same review — removing coalescing trades a proven-but-unmeasured optimization for a proven-elsewhere-but-also-unmeasured-here default, and Task 1's coalescer was itself introduced (`awesomux-private#94`, INT-377) partly to reduce "churn" that Task 2 could, in principle, reintroduce.

## Global Constraints

- No behavior change to what a tick *does* — `ghostty_app_tick` still drains everything accumulated since the previous tick. Only scheduling eagerness changes.
- Logging is local-only (`os.Logger`, existing `com.interactivebuffoonery.awesomux` subsystem convention) — no network calls, no cross-user telemetry.
- No new test framework or counters/aggregation — this project's spec (`docs/superpowers/specs/2026-07-22-wakeup-coalescer-removal-design.md`) explicitly scopes this to a scheduling simplification, not new branching logic.
- Preserve the "one `ghostty_app_tick` call drains every wakeup since the last tick" contract documentation — other code (`GHOSTTY_ACTION_PROGRESS_REPORT`'s synchronous-dispatch safety argument, `GhosttyRuntimeCallbacks.swift:288-290`) depends on a reader understanding this invariant, so deleting `GhosttyWakeupCoalescer`'s doc comment without relocating the contract explanation would leave that safety argument's citation dangling.
- Commit messages must state the libxev-batch-size mechanism as a hypothesis instrumented for follow-up, not as settled fact — per the architecture review's framing-falsification finding.
- `./script/swift-test.sh` must pass after every task.

---

### Task 1: Add tick-cadence debug logging (baseline, before removal)

**Files:**
- Modify: `Sources/awesoMux/Services/GhosttyRuntime.swift` (new logger declaration near the existing ones at lines 69-84; new stored property and log call in `tick()` at line 1297)
- Test: `Tests/awesoMuxTests/GhosttyRuntimeEventLoopWatchdogWiringTests.swift`

**Interfaces:**
- Consumes: `GhosttyRuntime.tick()` (existing signature, unmodified by this task's call-site — only its body changes).
- Produces: no new public API — this is an internal observability addition only. Task 2 does not depend on anything new this task produces; the two tasks touch disjoint concerns (logging vs. call-site coalescing) and are ordered only to get a before/after baseline, not because of a code dependency.

- [ ] **Step 1: Write a test exercising two consecutive `tick()` calls**

  In `Tests/awesoMuxTests/GhosttyRuntimeEventLoopWatchdogWiringTests.swift`, add a second test to the existing suite:

  ```swift
  @Test("tick() handles repeated calls without issue")
  func tickHandlesRepeatedCalls() {
      let runtime = GhosttyRuntime()
      defer { runtime.discardAllSurfaces() }
      runtime.tick()
      let afterFirst = runtime.lastEventLoopTickAtForTesting
      runtime.tick()
      #expect(runtime.lastEventLoopTickAtForTesting > afterFirst)
  }
  ```

  This exercises both the first-call (`lastTickLoggedAt == nil`) and second-call (`lastTickLoggedAt` set) branches the log line below adds.

- [ ] **Step 2: Run the test to verify it passes against the current code**

  Run: `swift test --filter GhosttyRuntimeEventLoopWatchdogWiringTests`
  Expected: PASS (this test doesn't require the log line to exist — it establishes the regression baseline before Step 3's change).

- [ ] **Step 3: Add the tick-cadence logger and log call**

  In `Sources/awesoMux/Services/GhosttyRuntime.swift`, add a new logger next to the existing ones (after line 83's `terminalDiagnosticsLogger` block):

  ```swift
      nonisolated private static let tickCadenceLogger = Logger(
          subsystem: "com.interactivebuffoonery.awesomux",
          category: "GhosttyRuntimeTick"
      )
  ```

  Then replace `tick()` (originally lines 1297-1303):

  ```swift
      func tick() {
          guard let app else {
              return
          }

          ghostty_app_tick(app)
          eventLoopWatchdog?.recordTick()
      }
  ```

  with:

  ```swift
      @ObservationIgnored
      private var lastTickLoggedAt: Date?

      func tick() {
          guard let app else {
              return
          }

          let now = Date()
          if let last = lastTickLoggedAt {
              Self.tickCadenceLogger.debug(
                  "tick fired \(now.timeIntervalSince(last), format: .fixed(precision: 3))s after previous tick"
              )
          }
          lastTickLoggedAt = now

          ghostty_app_tick(app)
          eventLoopWatchdog?.recordTick()
      }
  ```

- [ ] **Step 4: Run the test again to verify it still passes**

  Run: `swift test --filter GhosttyRuntimeEventLoopWatchdogWiringTests`
  Expected: PASS — both `tickRecordsHeartbeat` and `tickHandlesRepeatedCalls` succeed.

- [ ] **Step 5: Run the full suite**

  Run: `./script/swift-test.sh`
  Expected: all tests pass.

- [ ] **Step 6: Commit**

  ```bash
  git add Sources/awesoMux/Services/GhosttyRuntime.swift Tests/awesoMuxTests/GhosttyRuntimeEventLoopWatchdogWiringTests.swift
  git commit -m "$(cat <<'EOF'
  feat(ghostty): log tick cadence at debug level

  Local-only os.Logger signal (no network, no cross-user data), added
  before Task 2's wakeup-coalescer removal so tick clustering has a
  before/after baseline instead of only an after. Relevant to #176.

  Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
  EOF
  )"
  ```

---

### Task 2: Remove the coalescing latch

**Files:**
- Modify: `Sources/awesoMux/Services/GhosttyRuntimeCallbacks.swift:14-30` (the `wakeup(_:)` function)
- Modify: `Sources/awesoMux/Services/GhosttyRuntimeCallbacks.swift:288-290` (stale cross-reference comment inside the `GHOSTTY_ACTION_PROGRESS_REPORT` case)
- Modify: `Sources/awesoMux/Services/GhosttyRuntimeCallbacks.swift:783-820` (delete `GhosttyWakeupCoalescer` doc comment + class; keep `awesoMuxGhosttyWakeup` at 822-824 unchanged — it only forwards to `GhosttyRuntime.wakeup`)
- Modify: `Sources/awesoMux/Services/GhosttyRuntime.swift` (remove the `wakeupCoalescer` property — was at lines 190-191 before Task 1's insertions; locate it by content, just above the `performanceSampler` property, since Task 1 shifted line numbers below its own insertion point)

**Interfaces:**
- Produces: `GhosttyRuntime.wakeup(_:)` keeps its existing signature (`nonisolated static func wakeup(_ userdata: UnsafeMutableRawPointer?)`) and remains the sole call site that invokes `ghostty_app_tick` (via `tick()`), inside `Task { @MainActor in }` — Task 1's log line and existing tests (`ProgressReportPaneRecycleAtomicityTests.swift:23`) rely on that invariant continuing to hold.

There is no new unit-testable branch in this task's Swift diff — it's a deletion that changes C-callback scheduling cadence, which isn't observable from Swift Testing without a live `ghostty_app_t` event loop. Verification is: the change compiles, the existing test suite still passes, and — per the architecture review — a manual stress smoke test specifically targets the wakeup-storm shadow path this task's diff creates (see Step 6).

- [ ] **Step 1: Replace the coalesced `wakeup(_:)` with a direct per-wakeup dispatch**

  In `Sources/awesoMux/Services/GhosttyRuntimeCallbacks.swift`, replace lines 14-30:

  ```swift
  extension GhosttyRuntime {
      nonisolated static func wakeup(_ userdata: UnsafeMutableRawPointer?) {
          guard let userdata else {
              return
          }

          let runtime = Unmanaged<GhosttyRuntime>
              .fromOpaque(userdata)
              .takeUnretainedValue()

          runtime.wakeupCoalescer.schedule {
              Task { @MainActor in
                  runtime.wakeupCoalescer.clearPending()
                  runtime.tick()
              }
          }
      }
  ```

  with:

  ```swift
  extension GhosttyRuntime {
      /// Schedules a `tick()` for every libghostty wakeup callback — no
      /// coalescing. Matches upstream's macOS reference integration
      /// (`DispatchQueue.main.async { appTick() }` per wakeup in
      /// `Ghostty.App.swift`) rather than batching multiple wakeups into one
      /// drain. See docs/superpowers/specs/2026-07-22-wakeup-coalescer-removal-design.md
      /// for the working hypothesis: batching may make libghostty's per-tick
      /// I/O completion submissions larger, which is one plausible trigger
      /// shape for an open upstream libxev kqueue bug (mitchellh/libxev#122)
      /// — not a confirmed mechanism. Task 1's tick-cadence log line exists
      /// to gather evidence either way; treat this comment as a hypothesis,
      /// not a settled explanation.
      ///
      /// Correctness note: one `ghostty_app_tick(app)` call drains every
      /// event represented by wakeups that arrived since the previous tick,
      /// so scheduling one tick per wakeup (rather than exactly once per
      /// batch) never double-processes anything — it just means more,
      /// smaller ticks instead of fewer, larger ones.
      nonisolated static func wakeup(_ userdata: UnsafeMutableRawPointer?) {
          guard let userdata else {
              return
          }

          let runtime = Unmanaged<GhosttyRuntime>
              .fromOpaque(userdata)
              .takeUnretainedValue()

          Task { @MainActor in
              runtime.tick()
          }
      }
  ```

- [ ] **Step 2: Fix the stale cross-reference comment**

  Still in `GhosttyRuntimeCallbacks.swift`, in the `GHOSTTY_ACTION_PROGRESS_REPORT` case comment block, find this sentence (around line 288-290):

  ```swift
            // drains — and this codebase calls `ghostty_app_tick` ONLY from
            // inside `Task { @MainActor in }` in `wakeup(_:)` (see
            // `GhosttyWakeupCoalescer`'s doc comment above `tick()`). So
  ```

  Replace with:

  ```swift
            // drains — and this codebase calls `ghostty_app_tick` ONLY from
            // inside `Task { @MainActor in }` in `wakeup(_:)` (see
            // `wakeup(_:)`'s doc comment above). So
  ```

- [ ] **Step 3: Delete `GhosttyWakeupCoalescer`**

  Still in `GhosttyRuntimeCallbacks.swift`, delete the entire doc comment + class (originally lines 783-820):

  ```swift
  /// Latch-style coalescer for libghostty wakeup callbacks. The first wakeup
  /// after a quiet period flips `isPending` and runs `operation`; subsequent
  /// wakeups are dropped until `clearPending()` is called.
  ///
  /// Correctness depends on a libghostty contract: one `ghostty_app_tick(app)`
  /// call drains every event represented by wakeups that arrived since the
  /// previous tick. Upstream's macOS reference integration relies on the same
  /// drain-on-tick behavior, so this is sound as long as we keep using
  /// `ghostty_app_tick` as the work-doing call inside the operation. If a
  /// future libghostty release changes that contract, dropped wakeups become
  /// dropped work and this coalescer needs revisiting.
  ///
  /// The caller is responsible for invoking `clearPending()` from inside the
  /// operation (or its continuation) — preferably *before* doing the work, so a
  /// wakeup arriving during the work re-arms the latch and schedules another
  /// pass instead of being silently absorbed.
  final class GhosttyWakeupCoalescer: @unchecked Sendable {
      private let lock = NSLock()
      private var isPending = false

      func schedule(_ operation: () -> Void) {
          lock.lock()
          guard !isPending else {
              lock.unlock()
              return
          }
          isPending = true
          lock.unlock()

          operation()
      }

      func clearPending() {
          lock.lock()
          isPending = false
          lock.unlock()
      }
  }

  ```

  Leave the following `awesoMuxGhosttyWakeup` C-bridging function untouched — it only forwards to `GhosttyRuntime.wakeup` and doesn't reference the coalescer.

- [ ] **Step 4: Remove the now-unused `wakeupCoalescer` property**

  In `Sources/awesoMux/Services/GhosttyRuntime.swift`, find and delete:

  ```swift
      @ObservationIgnored
      let wakeupCoalescer = GhosttyWakeupCoalescer()

  ```

  (Delete the property and its blank trailing line; it sits just above the `performanceSampler` property declaration — locate by content, not by the original line numbers, since Task 1's insertions shifted everything below its own edit point.)

- [ ] **Step 5: Build and run the full test suite**

  Run: `./script/swift-test.sh`
  Expected: all existing tests pass, including `GhosttyRuntimeEventLoopWatchdogWiringTests` (both tests from Task 1) and `ProgressReportPaneRecycleAtomicityTests` — no references to `GhosttyWakeupCoalescer` or `wakeupCoalescer` remain anywhere (confirm with `grep -rn "wakeupCoalescer\|GhosttyWakeupCoalescer" Sources/ Tests/` returning no results).

- [ ] **Step 6: Manual stress smoke test (wakeup-storm shadow path)**

  This targets the failure mode the architecture review named: removing coalescing means every wakeup now spawns its own `Task { @MainActor in }`, and a high-frequency wakeup burst (heavy/fast terminal output) is untested by anything above. Run the built app (`./script/build_and_run.sh`), open a pane, and run something that produces a fast, sustained output burst — e.g. `yes | head -n 2000000` or tailing a large file quickly. While it runs:
  - Confirm the app stays responsive (sidebar clicks, typing in another pane) — no visible stutter beyond what the same test showed *before* this change.
  - Watch Activity Monitor's CPU% for the awesoMux process during the burst — note it, no hard pass/fail threshold defined (none exists yet to compare against), but flag to eD if it looks materially worse than pre-change behavior felt.
  - Check `log stream --predicate 'subsystem == "com.interactivebuffoonery.awesomux" AND category == "GhosttyRuntimeTick"' --level debug` during the burst to see actual tick cadence — this is the baseline-vs-after comparison Task 1's logging exists to enable.

  This step has no automated pass/fail — it's a judgment-call smoke test the architecture review specifically requested because no existing test covers this shadow path. Report what you observed in the task's completion notes.

- [ ] **Step 7: Commit**

  ```bash
  git add Sources/awesoMux/Services/GhosttyRuntimeCallbacks.swift Sources/awesoMux/Services/GhosttyRuntime.swift
  git commit -m "$(cat <<'EOF'
  fix(ghostty): remove wakeup coalescing, tick once per callback

  Working hypothesis, not a confirmed root cause: the app-wide
  coalescing latch let PTY output from multiple panes pile up before
  one ghostty_app_tick call drained it, which may produce larger I/O
  completion submissions than stock Ghostty's uncoalesced per-wakeup
  dispatch — one plausible trigger shape for an open upstream libxev
  kqueue bug (mitchellh/libxev#122), itself a likely contributor to the
  "Terminal Engine Unresponsive" alert (#176). This change matches
  stock Ghostty's proven-at-scale behavior regardless of whether the
  batch-size mechanism is exactly right; Task 1's tick-cadence logging
  exists to confirm or falsify it going forward.

  Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
  EOF
  )"
  ```

---

## Self-Review Notes

- **Spec coverage:** Change 1 (remove coalescer) → Task 2. Change 2 (log line) → Task 1, moved earlier per architecture review for baseline capture. "Out of scope" items (per-surface latching, bounded coalescing, watchdog changes, libxev pin bump) have no corresponding task, correctly.
- **Placeholder scan:** No TBD/TODO; every step has complete code. Step 6's lack of a hard pass/fail threshold is an intentional judgment-call smoke test, not a placeholder — named as such.
- **Type consistency:** `wakeup(_:)` signature, `tick()` signature, and `lastEventLoopTickAtForTesting` (used unchanged from the existing test) match across both tasks.
- **Dangling-reference check:** confirmed via `grep -rn "GhosttyWakeupCoalescer\|wakeupCoalescer"` in the worktree that the only three call sites are the ones covered in Task 2 (Steps 1, 3, 4) plus the comment in Step 2 — no other file references the deleted class.
- **Architecture review findings folded in:** task order swapped for baseline capture; Task 2 gained Step 6 (stress smoke test); both commit messages softened from asserted mechanism to instrumented hypothesis; Provenance Note section added above explaining why.
