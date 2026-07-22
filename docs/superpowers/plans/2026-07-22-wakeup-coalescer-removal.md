# Wakeup Coalescer Removal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove `GhosttyWakeupCoalescer`'s batching so every libghostty wakeup schedules its own tick immediately (matching stock Ghostty's macOS reference integration), and add a debug-level log line so tick cadence is observable going forward.

**Architecture:** `GhosttyRuntime.wakeup(_:)` (`Sources/awesoMux/Services/GhosttyRuntimeCallbacks.swift`) is the single call site where every libghostty `wakeup_cb` invocation currently routes through an app-wide latch (`GhosttyWakeupCoalescer`) before scheduling `GhosttyRuntime.tick()`. This plan deletes the latch and its backing class so `wakeup(_:)` unconditionally schedules one `Task { @MainActor in runtime.tick() }` per callback, then adds a single `Logger.debug` call inside `tick()` (`Sources/awesoMux/Services/GhosttyRuntime.swift`) reporting elapsed time since the previous tick.

**Tech Stack:** Swift 6 strict concurrency (`@MainActor`-isolated `GhosttyRuntime`), `os.Logger`, Swift Testing (`@Test`/`#expect`).

## Global Constraints

- No behavior change to what a tick *does* — `ghostty_app_tick` still drains everything accumulated since the previous tick. Only scheduling eagerness changes.
- Logging is local-only (`os.Logger`, existing `com.interactivebuffoonery.awesomux` subsystem convention) — no network calls, no cross-user telemetry.
- No new test framework or counters/aggregation — this project's spec (`docs/superpowers/specs/2026-07-22-wakeup-coalescer-removal-design.md`) explicitly scopes this to a scheduling simplification, not new branching logic.
- Preserve the "one `ghostty_app_tick` call drains every wakeup since the last tick" contract documentation — other code (`GHOSTTY_ACTION_PROGRESS_REPORT`'s synchronous-dispatch safety argument, `GhosttyRuntimeCallbacks.swift:288-290`) depends on a reader understanding this invariant, so deleting `GhosttyWakeupCoalescer`'s doc comment without relocating the contract explanation would leave that safety argument's citation dangling.
- `./script/swift-test.sh` must pass after every task.

---

### Task 1: Remove the coalescing latch

**Files:**
- Modify: `Sources/awesoMux/Services/GhosttyRuntimeCallbacks.swift:14-30` (the `wakeup(_:)` function)
- Modify: `Sources/awesoMux/Services/GhosttyRuntimeCallbacks.swift:288-290` (stale cross-reference comment inside the `GHOSTTY_ACTION_PROGRESS_REPORT` case)
- Modify: `Sources/awesoMux/Services/GhosttyRuntimeCallbacks.swift:783-820` (delete `GhosttyWakeupCoalescer` doc comment + class; keep `awesoMuxGhosttyWakeup` at 822-824 unchanged — it only forwards to `GhosttyRuntime.wakeup`)
- Modify: `Sources/awesoMux/Services/GhosttyRuntime.swift:190-191` (remove the `wakeupCoalescer` property)

**Interfaces:**
- Produces: `GhosttyRuntime.wakeup(_:)` keeps its existing signature (`nonisolated static func wakeup(_ userdata: UnsafeMutableRawPointer?)`) and remains the sole call site that invokes `ghostty_app_tick` (via `tick()`), inside `Task { @MainActor in }` — Task 2 and existing tests (`ProgressReportPaneRecycleAtomicityTests.swift:23`) rely on that invariant continuing to hold.

There is no new unit-testable branch in this task — it's a deletion that changes C-callback scheduling cadence, which isn't observable from Swift Testing without a live `ghostty_app_t` event loop. Verification is: the change compiles, and the existing test suite (which already exercises `tick()` directly) still passes.

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
      /// for why: batching made libghostty's per-tick I/O completion count
      /// bigger, which is the exact shape that trips an open upstream libxev
      /// kqueue bug (mitchellh/libxev#122).
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

  In `Sources/awesoMux/Services/GhosttyRuntime.swift`, delete lines 190-191:

  ```swift
      @ObservationIgnored
      let wakeupCoalescer = GhosttyWakeupCoalescer()

  ```

  (Delete the property and its blank trailing line; leave the surrounding properties — `performanceSampler` above it in source order stays where it is relative to what remains.)

- [ ] **Step 5: Build and run the full test suite**

  Run: `./script/swift-test.sh`
  Expected: all existing tests pass, including `GhosttyRuntimeEventLoopWatchdogWiringTests` (`tickRecordsHeartbeat`) and `ProgressReportPaneRecycleAtomicityTests` — no references to `GhosttyWakeupCoalescer` or `wakeupCoalescer` remain anywhere (confirm with `grep -rn "wakeupCoalescer\|GhosttyWakeupCoalescer" Sources/ Tests/` returning no results).

- [ ] **Step 6: Commit**

  ```bash
  git add Sources/awesoMux/Services/GhosttyRuntimeCallbacks.swift Sources/awesoMux/Services/GhosttyRuntime.swift
  git commit -m "$(cat <<'EOF'
  fix(ghostty): remove wakeup coalescing, tick once per callback

  The app-wide coalescing latch let PTY output from multiple panes pile
  up before one ghostty_app_tick call drained it, producing larger I/O
  completion batches than stock Ghostty's uncoalesced per-wakeup
  dispatch. Larger batches are the exact shape that trips an open
  upstream libxev kqueue bug (mitchellh/libxev#122), which is the root
  cause of the "Terminal Engine Unresponsive" alert (#176).

  Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
  EOF
  )"
  ```

---

### Task 2: Add tick-cadence debug logging

**Files:**
- Modify: `Sources/awesoMux/Services/GhosttyRuntime.swift` (new logger declaration near the existing ones at lines 69-84; new stored property and log call in `tick()` at line 1297)
- Test: `Tests/awesoMuxTests/GhosttyRuntimeEventLoopWatchdogWiringTests.swift`

**Interfaces:**
- Consumes: `GhosttyRuntime.tick()` (unchanged signature, produced by the existing codebase and untouched by Task 1's call-site change).
- Produces: no new public API — this is an internal observability addition only.

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

  Local-only os.Logger signal (no network, no cross-user data) so if
  the "Terminal Engine Unresponsive" alert (#176) recurs after removing
  wakeup coalescing, tick clustering is visible in `log stream` instead
  of requiring another guess.

  Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
  EOF
  )"
  ```

---

## Self-Review Notes

- **Spec coverage:** Change 1 (remove coalescer) → Task 1. Change 2 (log line) → Task 2. "Out of scope" items (per-surface latching, bounded coalescing, watchdog changes, libxev pin bump) have no corresponding task, correctly.
- **Placeholder scan:** No TBD/TODO; every step has complete code.
- **Type consistency:** `wakeup(_:)` signature, `tick()` signature, and `lastEventLoopTickAtForTesting` (used unchanged from the existing test) match across both tasks.
- **Dangling-reference check (specific to this plan):** confirmed via `grep -rn "GhosttyWakeupCoalescer\|wakeupCoalescer"` in the worktree that the only three call sites are the ones covered in Task 1 (Steps 1, 3, 4) plus the comment in Step 2 — no other file references the deleted class.
