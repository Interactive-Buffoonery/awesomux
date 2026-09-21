import AwesoMuxBridgeProtocol
import AwesoMuxCore
import Testing
@testable import awesoMux

@Suite("Session Manager presentation")
struct SessionManagerPresentationTests {
    @Test("lifecycle chooses the safe primary action")
    func primaryActions() throws {
        #expect(row(.owned).primaryAction == .open)
        #expect(row(.detachedRestorable).primaryAction == .restore)
        #expect(row(.abandoned).primaryAction == .recover)
        #expect(row(.expired).primaryAction == .recover)
        #expect(row(.inUseElsewhere).primaryAction == nil)
    }

    @Test("searches human metadata and full UUID case-insensitively")
    func search() throws {
        let row = row(.abandoned)
        #expect(row.matches(query: "résumé"))
        #expect(row.matches(query: "WORK"))
        #expect(row.matches(query: "development"))
        #expect(row.matches(query: row.id.rawValue))
        #expect(!row.matches(query: "missing"))
    }

    private func row(_ lifecycle: DaemonLifecycle) -> DaemonRow {
        DaemonRow(
            id: TerminalSessionID(rawValue: "01234567-abcd")!,
            pid: 1, createdEpoch: 1, clients: 0, lifecycle: lifecycle,
            activity: .idle, pinned: false, owner: nil,
            label: "Résumé", directory: "/Users/demo/Development/project",
            groupName: "Work", agentKind: .codex
        )
    }
}
