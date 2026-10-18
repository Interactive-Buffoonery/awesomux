import AwesoMuxBridgeProtocol
import AwesoMuxCore
import Testing
@testable import awesoMux

@Suite("Session Manager presentation")
struct SessionManagerPresentationTests {
    @Test(
        "lifecycle chooses the safe primary action",
        arguments: [
            (DaemonLifecycle.owned, SessionManagerPrimaryAction?.some(.open)),
            (.detachedRestorable, .restore), (.abandoned, .recover), (.expired, .recover), (.inUseElsewhere, nil),
        ])
    func primaryActions(lifecycle: DaemonLifecycle, expected: SessionManagerPrimaryAction?) throws {
        #expect(try row(lifecycle).primaryAction == expected)
    }

    private func row(_ lifecycle: DaemonLifecycle) throws -> DaemonRow {
        DaemonRow(
            id: try #require(TerminalSessionID(rawValue: "01234567-abcd")),
            pid: 1, createdEpoch: 1, clients: 0, lifecycle: lifecycle,
            activity: .idle, pinned: false, owner: nil,
            label: "Résumé", directory: "/Users/demo/Development/project",
            groupName: "Work", agentKind: .codex
        )
    }
}
