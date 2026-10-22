import Testing

@testable import AwesoMuxCore

/// Issue #311: `SessionStore.updatePane` publishes `groups` for a durable change
/// and routes a chrome-text-only change to the live-title channel instead. That
/// split used to be two hand-maintained field lists — the reducer's early-out and
/// the facade's publish gate, exact complements of each other. A field added to
/// the reducer's list and forgotten in the facade's would have been classified
/// display-only and landed silently, freezing every consumer not on the live-title
/// channel: the precise failure #311 exists to fix.
///
/// `PaneLayoutReducer.paneChangeKind` is now the single list both decisions read.
/// These tests pin the runtime classification of pane mutations.
@Suite("Pane change classification (#311)")
struct PaneChangeClassificationTests {

    private static func basePane() -> TerminalPane {
        TerminalPane(
            title: "pane",
            workingDirectory: "/tmp",
            remoteHost: "build-box",
            remoteSSHTarget: "build",
            pendingRemoteSSHTarget: "queued",
            remoteWorkingDirectory: "/srv",
            liveTerminalTitle: "pane",
            progressReport: TerminalProgressReport(state: .set, progress: 10),
            executionPlan: .local
        )
    }

    /// Every field `updatePane` can move that carries runtime behaviour. Both
    /// operands come from ONE base pane with a single field mutated, so the
    /// verdict can only be that field's doing — building two panes from a factory
    /// would compare fresh `id`s as well and stay green with the field deleted.
    @Test(arguments: Self.classificationCases)
    func classifiesMutation(name: String, mutate: @Sendable (inout TerminalPane) -> Void, expected: PaneLayoutReducer.PaneChangeKind) {
        let old = Self.basePane()
        var new = old
        mutate(&new)
        #expect(PaneLayoutReducer.paneChangeKind(from: old, to: new) == expected, "\(name)")
    }

    private static let classificationCases: [(String, @Sendable (inout TerminalPane) -> Void, PaneLayoutReducer.PaneChangeKind)] = [
        ("workingDirectory", { $0.workingDirectory = "/var" }, PaneLayoutReducer.PaneChangeKind.durable),
        ("remoteHost", { $0.remoteHost = "other-box" }, PaneLayoutReducer.PaneChangeKind.durable),
        ("remoteSSHTarget", { $0.remoteSSHTarget = "other" }, PaneLayoutReducer.PaneChangeKind.durable),
        (
            "hasConsumedManagedSSHWorkspaceOffer", { $0.hasConsumedManagedSSHWorkspaceOffer = true },
            PaneLayoutReducer.PaneChangeKind.durable
        ),
        ("pendingRemoteSSHTarget", { $0.pendingRemoteSSHTarget = nil }, PaneLayoutReducer.PaneChangeKind.durable),
        ("hasObservedPendingRemoteSSHProcess", { $0.hasObservedPendingRemoteSSHProcess = true }, PaneLayoutReducer.PaneChangeKind.durable),
        ("remoteWorkingDirectory", { $0.remoteWorkingDirectory = "/srv/other" }, PaneLayoutReducer.PaneChangeKind.durable),
        ("remoteConnectionHealth", { $0.remoteConnectionHealth = .possiblyStale }, PaneLayoutReducer.PaneChangeKind.durable),
        ("progressReport", { $0.progressReport = nil }, PaneLayoutReducer.PaneChangeKind.durable),
        ("title", { $0.title = "cargo build" }, .displayOnly),
        ("liveTerminalTitle", { $0.liveTerminalTitle = "cargo build" }, .displayOnly),
        ("identical", { _ in }, .unchanged),
        (
            "durable and title",
            {
                $0.title = "cargo build"; $0.liveTerminalTitle = "cargo build"; $0.workingDirectory = "/var"
            }, .durable
        ),
    ]


}
