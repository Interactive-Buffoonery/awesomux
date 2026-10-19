import Foundation
import Testing
@testable import AwesoMuxCore

@MainActor
@Suite("RecentlyClosedWorkspace — capture, persistence, reopen")
struct RecentlyClosedWorkspaceTests {

    // MARK: - Helpers

    private static func makeStore(
        sessionCount: Int = 1,
        groupName: String = "awesoMux"
    ) -> SessionStore {
        var sessions: [TerminalSession] = []
        for index in 0..<sessionCount {
            sessions.append(
                TerminalSession(
                    title: "ws-\(index)",
                    workingDirectory: NSHomeDirectory(),
                    isTitleUserEdited: true,
                    agentKind: .shell,
                    agentState: .idle
                ))
        }
        let group = SessionGroup(name: groupName, sessions: sessions)
        let store = SessionStore(groups: [group])
        store.selectedSessionID = sessions.first?.id
        return store
    }

    // MARK: - TTL

    @Test("expired entries are pruned at restore and before persistence", arguments: [false, true])
    func pruneOnRestore(beforePersistence: Bool) throws {
        let stale = RecentlyClosedWorkspace(
            sessionID: UUID(),
            title: "stale",
            isTitleUserEdited: false,
            agentKind: .shell,
            layout: .pane(TerminalPane(title: "stale", workingDirectory: NSHomeDirectory(), executionPlan: .local)),
            activePaneID: UUID(),
            groupID: UUID(),
            groupName: "ghost-group",
            groupRemote: nil,
            indexInGroup: 0,
            closedAt: Date().addingTimeInterval(-(SessionStore.recentlyClosedTTL + 60))
        )
        let fresh = RecentlyClosedWorkspace(
            sessionID: UUID(),
            title: "fresh",
            isTitleUserEdited: false,
            agentKind: .shell,
            layout: .pane(TerminalPane(title: "fresh", workingDirectory: NSHomeDirectory(), executionPlan: .local)),
            activePaneID: UUID(),
            groupID: UUID(),
            groupName: "live-group",
            groupRemote: nil,
            indexInGroup: 0,
            closedAt: Date()
        )

        let snapshot = SessionSnapshot(
            groups: [SessionGroup(name: "g", sessions: [])],
            selectedSessionID: nil,
            recentlyClosed: [fresh, stale]
        )
        let store = SessionStore(restoring: snapshot)

        if beforePersistence {
            store.recentlyClosed = [fresh, stale]
        }
        let entries = beforePersistence ? store.snapshot().recentlyClosed : store.recentlyClosed
        #expect(entries.count == 1)
        #expect(entries.first?.title == "fresh")
    }


    @Test("transient recovery never reaches the persisted file")
    func transientNotPersisted() throws {
        let shell = TerminalSession(
            title: "throwaway shell", workingDirectory: NSHomeDirectory(), isTitleUserEdited: false, agentKind: .shell)
        let store = SessionStore(groups: [SessionGroup(name: "g", sessions: [shell])])
        store.closeSession(id: shell.id, origin: .processExit)
        #expect(store.lastClosedTransient?.sessionID == shell.id)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("session-state.json")
        try JSONEncoder().encode(store.snapshot()).write(to: url)
        let persisted = try Data(contentsOf: url)
        let json = try #require(JSONSerialization.jsonObject(with: persisted) as? [String: Any])
        #expect(json["lastClosedTransient"] == nil)
        #expect((json["recentlyClosed"] as? [Any] ?? []).isEmpty)
        #expect(!String(decoding: persisted, as: UTF8.self).contains(shell.id.uuidString))
        let restored = SessionStore(restoring: try SessionSnapshot.decode(from: persisted))
        #expect(!restored.canReopenClosedWorkspace)
    }

    // MARK: - Schema compatibility

    @Test("malformed recentlyClosed entry is skipped, rest of snapshot survives")
    func malformedEntryIsIsolated() throws {
        let valid = RecentlyClosedWorkspace(
            sessionID: UUID(),
            title: "ok",
            isTitleUserEdited: false,
            agentKind: .shell,
            layout: .pane(TerminalPane(title: "ok", workingDirectory: NSHomeDirectory(), executionPlan: .local)),
            activePaneID: UUID(),
            groupID: UUID(),
            groupName: "g",
            groupRemote: nil,
            indexInGroup: 0,
            closedAt: Date()
        )
        let validData = try JSONEncoder().encode([valid])
        let validJSONFragment = String(data: validData, encoding: .utf8)!
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))

        // Build a snapshot with one valid entry and one structurally-broken
        // entry (a string where an object is expected). The tolerant decoder
        // should keep the valid entry.
        let json = """
            {
              "schemaVersion": 1,
              "groups": [
                {
                  "id": "22222222-2222-2222-2222-222222222222",
                  "name": "g",
                  "sessions": []
                }
              ],
              "recentlyClosed": ["this should be an object, not a string", \(validJSONFragment)]
            }
            """.data(using: .utf8)!

        let snapshot = try SessionSnapshot.decode(from: json)
        #expect(snapshot.recentlyClosed.count == 1)
        #expect(snapshot.recentlyClosed.first?.title == "ok")
    }

    @Test("reopen runs captured title through the sanitiser (drops RTL override)")
    func reopenSanitisesTitle() throws {
        let entry = RecentlyClosedWorkspace(
            sessionID: UUID(),
            // U+202E RIGHT-TO-LEFT OVERRIDE in the middle of a title
            title: "safe\u{202E}danger",
            isTitleUserEdited: true,
            agentKind: .shell,
            layout: .pane(TerminalPane(title: "leaf", workingDirectory: NSHomeDirectory(), executionPlan: .local)),
            activePaneID: UUID(),
            groupID: UUID(),
            groupName: "g",
            groupRemote: nil,
            indexInGroup: 0,
            closedAt: Date()
        )
        let store = Self.makeStore()
        store.recentlyClosed = [entry]

        let reopenedID = try #require(store.reopenMostRecentlyClosed())
        let reopened = try #require(store.session(id: reopenedID))
        #expect(!reopened.title.contains("\u{202E}"))
    }

    @Test(
        "close origin gates persistence of bare shells",
        arguments: [
            (SessionStore.CloseOrigin.user, true),
            (.processExit, false),
        ])
    func closePersistence(origin: SessionStore.CloseOrigin, persisted: Bool) throws {
        let shell = TerminalSession(
            title: "shell", workingDirectory: NSHomeDirectory(), isTitleUserEdited: false, agentKind: .shell, agentState: .idle)
        let store = SessionStore(groups: [SessionGroup(name: "g", sessions: [shell])])
        store.closeSession(id: shell.id, origin: origin)
        #expect(store.recentlyClosed.map(\.sessionID) == (persisted ? [shell.id] : []))
        #expect(store.lastClosedTransient?.sessionID == shell.id)
    }
}
