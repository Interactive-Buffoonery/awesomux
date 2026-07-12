import Foundation
import Testing
@testable import AwesoMuxCore

@Suite("Per-workspace notification mute (INT-598)")
struct WorkspaceNotificationMuteTests {
    // MARK: - Persistence

    @Test("notificationsMuted round-trips through the session snapshot")
    func mutedFlagRoundTrips() throws {
        let session = TerminalSession(
            title: "agent",
            workingDirectory: "~",
            notificationsMuted: true
        )
        let snapshot = SessionSnapshot(
            groups: [SessionGroup(name: "awesoMux", sessions: [session])],
            selectedSessionID: session.id
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: data)

        #expect(decoded.groups.first?.sessions.first?.notificationsMuted == true)
    }

    @Test("encode omits the key when unmuted, keeping old snapshots byte-stable")
    func unmutedSessionOmitsKey() throws {
        let session = TerminalSession(title: "agent", workingDirectory: "~")

        let data = try JSONEncoder().encode(session)
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(!json.contains("notificationsMuted"))
    }

    @Test("decode tolerates snapshots that predate the key")
    func absentKeyDecodesUnmuted() throws {
        let session = TerminalSession(title: "agent", workingDirectory: "~")
        var object = try #require(
            try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(session)
            ) as? [String: Any]
        )
        object.removeValue(forKey: "notificationsMuted")
        let data = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(TerminalSession.self, from: data)

        #expect(decoded.notificationsMuted == false)
    }

    @Test("restore reducer preserves the mute across relaunch sanitization")
    func restoreReducerPreservesMute() {
        let session = TerminalSession(
            title: "agent",
            workingDirectory: "~",
            notificationsMuted: true
        )
        let snapshot = SessionSnapshot(
            groups: [SessionGroup(name: "awesoMux", sessions: [session])],
            selectedSessionID: session.id
        )

        let components = SessionRestoreReducer.restoredComponents(from: snapshot)

        #expect(components.groups.first?.sessions.first?.notificationsMuted == true)
    }

    // MARK: - Store facade

    @MainActor
    @Test("setNotificationsMuted toggles the flag and feeds the muted list")
    func setNotificationsMutedTogglesAndLists() {
        let session = TerminalSession(title: "agent", workingDirectory: "~")
        let store = SessionStore(groups: [
            SessionGroup(name: "awesoMux", sessions: [session])
        ])

        #expect(store.mutedNotificationSessions.isEmpty)
        #expect(store.setNotificationsMuted(id: session.id, muted: true))
        #expect(store.session(id: session.id)?.notificationsMuted == true)
        #expect(store.mutedNotificationSessions.map(\.id) == [session.id])

        #expect(store.setNotificationsMuted(id: session.id, muted: false))
        #expect(store.session(id: session.id)?.notificationsMuted == false)
        #expect(store.mutedNotificationSessions.isEmpty)
    }

    @MainActor
    @Test("setNotificationsMuted returns false for an unknown session")
    func setNotificationsMutedUnknownSession() {
        let store = SessionStore(groups: [])

        #expect(!store.setNotificationsMuted(id: UUID(), muted: true))
    }

    @MainActor
    @Test("muting does not change unread totals or dock-badge contribution")
    func mutingKeepsUnreadTotals() {
        let session = TerminalSession(
            title: "agent",
            workingDirectory: "~",
            agentKind: .claudeCode,
            agentState: .needsAttention,
            unreadNotificationCount: 2
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "awesoMux", sessions: [session])
        ])
        let totalBefore = store.unreadNotificationTotal

        store.setNotificationsMuted(id: session.id, muted: true)

        // Decision under INT-598: muted workspaces keep contributing to
        // in-app visible state — unread badges and the dock badge total.
        #expect(store.unreadNotificationTotal == totalBefore)
        #expect(store.session(id: session.id)?.unreadNotificationCount == 2)
    }
}
