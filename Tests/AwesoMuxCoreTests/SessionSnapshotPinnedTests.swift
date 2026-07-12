import Foundation
import Testing
@testable import AwesoMuxCore

@Suite struct SessionSnapshotPinnedTests {
    private func makeSnapshot(pinned: [TerminalSession.ID]) -> SessionSnapshot {
        let session = TerminalSession(title: "alpha", workingDirectory: "~")
        return SessionSnapshot(
            groups: [SessionGroup(name: "One", sessions: [session])],
            selectedSessionID: session.id,
            pinnedSessionIDs: pinned
        )
    }

    @Test func roundTripsPinnedIDs() throws {
        let session = TerminalSession(title: "alpha", workingDirectory: "~")
        let snapshot = SessionSnapshot(
            groups: [SessionGroup(name: "One", sessions: [session])],
            selectedSessionID: nil,
            pinnedSessionIDs: [session.id]
        )
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: data)
        #expect(decoded.pinnedSessionIDs == [session.id])
    }

    @Test func missingKeyDecodesToEmpty() throws {
        let snapshot = makeSnapshot(pinned: [])
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: data)
        #expect(decoded.pinnedSessionIDs.isEmpty)
    }

    @Test func emptyPinnedOmitsKey() throws {
        let data = try JSONEncoder().encode(makeSnapshot(pinned: []))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["pinnedSessionIDs"] == nil)
    }

    @Test func malformedPinnedDecodesToEmpty() throws {
        var data = try JSONEncoder().encode(makeSnapshot(pinned: []))
        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["pinnedSessionIDs"] = ["not-a-uuid", 42]
        data = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: data)
        #expect(decoded.pinnedSessionIDs.isEmpty)
    }

    @Test func restoreDropsStaleAndDuplicatePins() {
        let live = TerminalSession(title: "alpha", workingDirectory: "~")
        let stale = UUID()
        let snapshot = SessionSnapshot(
            groups: [SessionGroup(name: "One", sessions: [live])],
            selectedSessionID: nil,
            pinnedSessionIDs: [stale, live.id, live.id]
        )
        let components = SessionRestoreReducer.restoredComponents(from: snapshot)
        #expect(components.pinnedSessionIDs == [live.id])
    }

    @Test @MainActor func replaceStateRestoresPins() {
        let live = TerminalSession(title: "alpha", workingDirectory: "~")
        let snapshot = SessionSnapshot(
            groups: [SessionGroup(name: "One", sessions: [live])],
            selectedSessionID: nil,
            pinnedSessionIDs: [live.id]
        )
        let store = SessionStore()
        store.replaceState(restoring: snapshot)
        #expect(store.pinnedSessionIDs == [live.id])
        #expect(store.snapshot().pinnedSessionIDs == [live.id])
    }
}
