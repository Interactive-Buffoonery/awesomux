import Foundation
import Testing
@testable import AwesoMuxCore

@Suite("SessionStoreIndex")
struct SessionStoreIndexTests {
    @Test("dedupes unread by first session id and records live panes")
    func buildDedupesUnreadAndRecordsLivePanes() throws {
        let sharedID = UUID()
        let first = TerminalSession(
            id: sharedID,
            title: "first",
            workingDirectory: "~",
            agentKind: .shell,
            unreadNotificationCount: 2
        )
        let duplicate = TerminalSession(
            id: sharedID,
            title: "duplicate",
            workingDirectory: "~",
            agentKind: .shell,
            unreadNotificationCount: 99
        )
        let other = TerminalSession(
            title: "other",
            workingDirectory: "~",
            agentKind: .codex,
            unreadNotificationCount: 3
        )

        let index = SessionStoreIndex.build(from: [
            SessionGroup(name: "one", sessions: [first]),
            SessionGroup(name: "two", sessions: [duplicate, other])
        ])

        #expect(index.positionsBySessionID[sharedID] == .init(groupIndex: 0, sessionIndex: 0))
        #expect(index.unreadNotificationTotal == 5)
        #expect(index.livePaneIDs == Set([first.activePaneID, duplicate.activePaneID, other.activePaneID]))
    }
}
