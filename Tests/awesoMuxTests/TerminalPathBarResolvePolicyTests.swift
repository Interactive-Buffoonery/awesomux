import AwesoMuxCore
import Foundation
import Testing

@testable import awesoMux

/// Truth table for `TerminalPathBarResolvePolicy.classify` — the INT-523 gate that
/// keeps title-only churn from re-walking the repo. Pure, so it tests without a view.
///
/// NOTE: this covers the *classifier* half only. The other load-bearing half — the
/// view's `lastResolveInputs` watermark advancing ONLY after `make()` commits (so a
/// substantive change interrupted by title churn is not mis-debounced) — lives in
/// `TerminalPathBarView`'s `.task` and is verified by live GUI smoke, not here.
@Suite("TerminalPathBarResolvePolicy")
struct TerminalPathBarResolvePolicyTests {
    private func inputs(
        paneID: TerminalPane.ID? = nil,
        cwd: String = "/Users/x/repo",
        executionPlan: PaneExecutionPlan = .local,
        remoteHost: String? = nil,
        health: RemoteConnectionHealth = .active,
        isActive: Bool = true
    ) -> TerminalPathBarResolvePolicy.ResolveInputs {
        .init(
            activePaneID: paneID,
            workingDirectory: cwd,
            executionPlan: executionPlan,
            remoteHost: remoteHost,
            remoteConnectionHealth: health,
            isActive: isActive
        )
    }

    @Test("first paint (no previous resolve) walks immediately")
    func firstPaint() {
        #expect(
            TerminalPathBarResolvePolicy.classify(previous: nil, current: inputs()) == .immediate)
    }

    @Test("title-only churn (identical resolve inputs) debounces — the INT-523 fix")
    func titleOnlyDebounces() {
        // Same cwd / pane / remote / focus → the only thing that could have changed
        // is the title, which ResolveInputs deliberately excludes. The fs/git walk
        // must NOT re-fire immediately on this.
        let a = inputs()
        #expect(TerminalPathBarResolvePolicy.classify(previous: a, current: a) == .debounced)
    }

    @Test("cwd change walks immediately")
    func cwdChange() {
        #expect(
            TerminalPathBarResolvePolicy.classify(
                previous: inputs(cwd: "/a"),
                current: inputs(cwd: "/b")
            ) == .immediate)
    }

    @Test("pane switch walks immediately")
    func paneSwitch() {
        #expect(
            TerminalPathBarResolvePolicy.classify(
                previous: inputs(paneID: UUID()),
                current: inputs(paneID: UUID())
            ) == .immediate)
    }

    @Test("remote-host flip walks immediately (stale local path must not stay clickable)")
    func remoteFlip() {
        #expect(
            TerminalPathBarResolvePolicy.classify(
                previous: inputs(remoteHost: nil),
                current: inputs(remoteHost: "webserver")
            ) == .immediate)
    }

    @Test("execution-plan flip walks immediately before shell observation")
    func executionPlanFlip() {
        let target = RemoteTarget(user: "", host: "webserver")!
        #expect(
            TerminalPathBarResolvePolicy.classify(
                previous: inputs(executionPlan: .local),
                current: inputs(executionPlan: .ssh(SSHExecution(target: target)))
            ) == .immediate)
    }

    @Test(
        "remote→local flip walks immediately (must not debounce back into a clickable local path)")
    func remoteToLocalFlip() {
        // The asymmetric direction the source comment flags as load-bearing: a pane
        // leaving SSH must resolve its now-valid local cwd/git promptly, not be
        // mistaken for title churn and debounced.
        #expect(
            TerminalPathBarResolvePolicy.classify(
                previous: inputs(remoteHost: "webserver"),
                current: inputs(remoteHost: nil)
            ) == .immediate)
    }

    @Test("connection-health change walks immediately")
    func healthChange() {
        #expect(
            TerminalPathBarResolvePolicy.classify(
                previous: inputs(health: .active),
                current: inputs(health: .possiblyStale)
            ) == .immediate)
    }

    @Test("focus regain walks immediately (catches a checkout made in the background)")
    func focusRegain() {
        #expect(
            TerminalPathBarResolvePolicy.classify(
                previous: inputs(isActive: false),
                current: inputs(isActive: true)
            ) == .immediate)
    }
}
