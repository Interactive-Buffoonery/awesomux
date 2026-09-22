import AwesoMuxBridgeProtocol
import AwesoMuxCore
import Testing
@testable import awesoMux

@Suite("Session Manager presentation")
struct SessionManagerPresentationTests {
    @Test("lifecycle chooses the safe primary action")
    func primaryActions() throws {
        #expect(try row(.owned).primaryAction == .open)
        #expect(try row(.detachedRestorable).primaryAction == .restore)
        #expect(try row(.abandoned).primaryAction == .recover)
        #expect(try row(.expired).primaryAction == .recover)
        #expect(try row(.inUseElsewhere).primaryAction == nil)
        #expect(SessionManagerPrimaryAction.open.successLabel(for: "Build") == "Opened session Build.")
        #expect(
            SessionManagerPrimaryAction.restore.successLabel(for: "Build")
                == "Restored session Build."
        )
        #expect(
            SessionManagerPrimaryAction.recover.successLabel(for: "Build")
                == "Recovered session Build."
        )
    }

    @Test("searches human metadata and full UUID case-insensitively")
    func search() throws {
        let row = try row(.abandoned)
        #expect(row.matches(query: "résumé"))
        #expect(row.matches(query: "WORK"))
        #expect(row.matches(query: "development"))
        #expect(row.matches(query: row.id.rawValue))
        #expect(!row.matches(query: "missing"))
    }

    @Test("localized session formats have runtime-compatible catalog keys")
    func localizedFormatKeys() throws {
        let keys = try AwesoMuxStringCatalog.keys()
        for key in [
            "Opened session %@.", "Restored session %@.", "Recovered session %@.",
            "%1$@ %2$@", "%1$@ %2$@…",
        ] {
            #expect(keys.contains(key), "Missing runtime localization key: \(key)")
        }
    }

    @Test("session names containing format specifiers remain literal")
    func percentBearingSessionName() {
        #expect(
            SessionManagerPrimaryAction.recover.successLabel(for: "Build 100% %@ %1$@")
                == "Recovered session Build 100% %@ %1$@."
        )
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
