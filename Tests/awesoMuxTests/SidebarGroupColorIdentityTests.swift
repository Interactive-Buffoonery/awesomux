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

    @Test(arguments: ["move", "override", "remove", "undo"])
    func rememberedColors(scenario: String) throws {
        let store = SessionStore(groups: [
            SessionGroup(name: "First", sessions: []),
            SessionGroup(name: scenario == "override" ? "awesoMux" : "Second", sessions: []),
            SessionGroup(name: "Third", sessions: []),
        ])
        if scenario != "move" { _ = store.removeGroup(id: store.groups[2].id) }
        let ids = store.groups.map(\.id)
        let original = Dictionary(
            uniqueKeysWithValues: store.groups.enumerated().map { ($0.element.id, accent($0.element, at: $0.offset)) })
        func assertRemembered(_ candidate: SessionStore) {
            for (index, group) in candidate.groups.enumerated() { #expect(accent(group, at: index) == original[group.id]) }
        }
        switch scenario {
        case "move":
            store.moveGroup(from: 2, to: 0)
            #expect(store.groups.map(\.id) == [ids[2], ids[0], ids[1]])
            assertRemembered(store)
            let restored = SessionStore(restoring: try SessionSnapshot.decode(from: JSONEncoder().encode(store.snapshot())))
            assertRemembered(restored)
        case "override":
            #expect(store.setGroupColor(id: ids[1], color: .yellow))
            store.moveGroup(from: 1, to: 0)
            #expect(accent(store.groups[0], at: 0) == .yellow)
            #expect(store.setGroupColor(id: ids[1], color: nil))
            #expect(store.renameGroup(id: ids[1], to: "Renamed"))
            assertRemembered(store)
            #expect(store.setGroupColor(id: ids[0], color: .red))
            #expect(accent(store.groups[1], at: 1) == .red)
            #expect(store.setGroupColor(id: ids[0], color: nil))
            assertRemembered(store)
        case "remove":
            #expect(store.removeGroup(id: ids[0]))
            assertRemembered(store)
            store.addSession(groupName: "New")
            let added = accent(store.groups[1], at: 1)
            store.moveGroup(from: 1, to: 0)
            #expect(accent(store.groups[0], at: 0) == added)
            #expect(accent(store.groups[1], at: 1) == original[ids[1]])
        default:
            let undo = UndoManager()
            undo.groupsByEvent = false
            store.undoManager = undo
            undo.beginUndoGrouping()
            store.moveGroup(from: 1, to: 0)
            undo.endUndoGrouping()
            #expect(store.groups[0].id == ids[1])
            assertRemembered(store)
            let snapshot = store.snapshot()
            undo.undo()
            #expect(store.groups[0].id == ids[0])
            assertRemembered(store)
            undo.redo()
            #expect(store.groups[0].id == ids[1])
            assertRemembered(store)
            let restored = SessionStore()
            restored.replaceState(restoring: snapshot)
            assertRemembered(restored)
        }
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
        let automatic = SessionStore(groups: [SessionGroup(name: "First", sessions: [])])
        #expect(accent(store.groups[0], at: 0) == accent(automatic.groups[0], at: 0))
    }

}
