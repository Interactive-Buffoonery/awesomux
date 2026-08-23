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
        let decoded = try SessionSnapshot.decode(from: data)

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

    @Test("pane move origin is additive Codable state")
    func paneMoveOriginCodable() throws {
        let sourceID = UUID()
        let paneID = UUID()
        let parentSplitID = UUID()
        let session = TerminalSession(
            title: "moved",
            workingDirectory: "~",
            moveOrigin: PaneMoveOrigin(
                sourceSessionID: sourceID,
                paneID: paneID,
                parentSplitID: parentSplitID,
                sibling: .pane(paneID),
                edge: .left,
                fraction: 0.42
            )
        )
        let decoded = try JSONDecoder().decode(
            TerminalSession.self,
            from: JSONEncoder().encode(session)
        )
        #expect(decoded.moveOrigin == session.moveOrigin)

        let plain = TerminalSession(title: "plain", workingDirectory: "~")
        let data = try JSONEncoder().encode(plain)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains("moveOrigin"))
        #expect(try JSONDecoder().decode(TerminalSession.self, from: data).moveOrigin == nil)
    }

    @Test("pane move origin encoding shape is stable")
    func paneMoveOriginEncodingShape() throws {
        let origin = PaneMoveOrigin(
            sourceSessionID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            paneID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            parentSplitID: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            sibling: .pane(UUID(uuidString: "44444444-4444-4444-4444-444444444444")!),
            edge: .left,
            fraction: 0.42
        )
        let object = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(origin)) as? NSDictionary
        )
        let expected: NSDictionary = [
            "sourceSessionID": "11111111-1111-1111-1111-111111111111",
            "paneID": "22222222-2222-2222-2222-222222222222",
            "parentSplitID": "33333333-3333-3333-3333-333333333333",
            "sibling": ["pane": ["_0": "44444444-4444-4444-4444-444444444444"]],
            "edge": "left",
            "fraction": 0.42,
        ]
        #expect(object == expected)
    }

    @Test("malformed pane move origin does not reject its session")
    func malformedPaneMoveOriginIsDropped() throws {
        let session = TerminalSession(title: "moved", workingDirectory: "~")
        var object = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(session))
                as? [String: Any]
        )
        let validOrigin: [String: Any] = [
            "sourceSessionID": UUID().uuidString,
            "paneID": session.activePaneID.uuidString,
            "parentSplitID": UUID().uuidString,
            "sibling": ["pane": ["_0": UUID().uuidString]],
            "edge": "left",
            "fraction": 0.5,
        ]
        var unknownEdge = validOrigin
        unknownEdge["edge"] = "futureEdge"
        object["moveOrigin"] = unknownEdge
        #expect(
            try JSONDecoder().decode(
                TerminalSession.self,
                from: JSONSerialization.data(withJSONObject: object)
            ).moveOrigin == nil
        )

        var unknownSibling = validOrigin
        unknownSibling["sibling"] = ["futureSibling": ["_0": UUID().uuidString]]
        object["moveOrigin"] = unknownSibling
        let decoded = try JSONDecoder().decode(
            TerminalSession.self, from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(decoded.id == session.id)
        #expect(decoded.moveOrigin == nil)
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
