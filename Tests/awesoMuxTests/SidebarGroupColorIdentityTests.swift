import AwesoMuxCore
import Foundation
import DesignSystem
import Testing
@testable import awesoMux

@Suite("Sidebar group color identity")
@MainActor
struct SidebarGroupColorIdentityTests {
    private func accent(_ group: SessionGroup, at index: Int) -> AwTintAccent {
        ProjectTint(group: group, index: index).accent
    }

    @Test func movingGroupsKeepsTheirExistingAutomaticColors() throws {
        let store = SessionStore(groups: [
            SessionGroup(name: "First", sessions: []),
            SessionGroup(name: "Second", sessions: []),
            SessionGroup(name: "Third", sessions: []),
        ])
        let original = store.groups.map { $0.id }
        store.moveGroup(from: 2, to: 0)
        #expect(store.groups.map(\.id) == [original[2], original[0], original[1]])
        #expect(accent(store.groups[0], at: 0) == .blue)
        #expect(accent(store.groups[1], at: 1) == .teal)
        #expect(accent(store.groups[2], at: 2) == .green)
        let data = try JSONEncoder().encode(store.snapshot())
        let restored = SessionStore(restoring: try SessionSnapshot.decode(from: data))
        #expect(accent(restored.groups[0], at: 0) == .blue)
        #expect(accent(restored.groups[1], at: 1) == .teal)
        #expect(accent(restored.groups[2], at: 2) == .green)
    }
    @Test func overridesAndDefaultSurviveMoves() {
        let first = SessionGroup(name: "First", sessions: [])
        let special = SessionGroup(name: "awesoMux", color: .yellow, sessions: [])
        let store = SessionStore(groups: [first, special])
        store.moveGroup(from: 1, to: 0)
        #expect(accent(store.groups[0], at: 0) == .yellow)
        #expect(store.setGroupColor(id: special.id, color: nil))
        #expect(accent(store.groups[0], at: 0) == .mauve)
        #expect(store.renameGroup(id: special.id, to: "Renamed"))
        #expect(accent(store.groups[0], at: 0) == .mauve)
        #expect(store.setGroupColor(id: first.id, color: .red))
        #expect(accent(store.groups[1], at: 1) == .red)
        #expect(store.setGroupColor(id: first.id, color: nil))
        #expect(accent(store.groups[1], at: 1) == .teal)
    }

    @Test func removingAnotherGroupKeepsColorsAndNewGroupsRememberTheirDefault() {
        let first = SessionGroup(name: "First", sessions: [])
        let store = SessionStore(groups: [first, SessionGroup(name: "Second", sessions: [])])
        #expect(store.removeGroup(id: first.id))
        #expect(accent(store.groups[0], at: 0) == .green)
        store.addSession(groupName: "New")
        store.moveGroup(from: 1, to: 0)
        #expect(accent(store.groups[0], at: 0) == .green)
        #expect(accent(store.groups[1], at: 1) == .green)
    }
    @Test func undoAndBulkRestoreKeepRememberedColors() {
        let store = SessionStore(groups: [
            SessionGroup(name: "First", sessions: []),
            SessionGroup(name: "Second", sessions: []),
        ])
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.undoManager = undo
        undo.beginUndoGrouping()
        store.moveGroup(from: 1, to: 0)
        undo.endUndoGrouping()
        #expect(accent(store.groups[0], at: 0) == .green)
        let snapshot = store.snapshot()
        undo.undo()
        #expect(accent(store.groups[0], at: 0) == .teal)
        undo.redo()
        #expect(accent(store.groups[0], at: 0) == .green)
        let replacement = SessionStore()
        replacement.replaceState(restoring: snapshot)
        #expect(accent(replacement.groups[0], at: 0) == .green)
        #expect(accent(replacement.groups[1], at: 1) == .teal)
    }

    @Test(arguments: [#""unknown""#, "42", #"{"bad":"shape"}"#, "null"])
    func malformedAutomaticColorFallsBackWithoutDroppingGroup(_ fragment: String) throws {
        let group = SessionGroup(name: "First", color: .red, sessions: [])
        let data = try JSONEncoder().encode(group)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["automaticColor"] = try JSONSerialization.jsonObject(with: Data(fragment.utf8), options: [.fragmentsAllowed])
        let decoded = try JSONDecoder().decode(
            SessionGroup.self, from: JSONSerialization.data(withJSONObject: object))
        let store = SessionStore(groups: [decoded])
        #expect(store.groups[0].id == group.id)
        #expect(accent(store.groups[0], at: 0) == .red)
        #expect(store.setGroupColor(id: group.id, color: nil))
        #expect(accent(store.groups[0], at: 0) == .teal)
    }

}
