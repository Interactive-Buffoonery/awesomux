import Foundation
import Testing
@testable import AwesoMuxCore

@MainActor
@Suite("SessionStore — Reorder (INT-330)")
struct SessionStoreReorderTests {
    private func makeSession(_ tag: String) -> TerminalSession {
        TerminalSession(
            title: "shell \(tag)",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .idle
        )
    }

    private func makeStore(
        groupSpecs: [(name: String, sessionTags: [String])],
        selectTag: String? = nil
    ) -> (SessionStore, [String: TerminalSession.ID], [String: SessionGroup.ID]) {
        var sessionIDs: [String: TerminalSession.ID] = [:]
        var groupIDs: [String: SessionGroup.ID] = [:]
        let groups: [SessionGroup] = groupSpecs.map { spec in
            let sessions = spec.sessionTags.map { tag -> TerminalSession in
                let s = makeSession(tag)
                sessionIDs[tag] = s.id
                return s
            }
            let group = SessionGroup(name: spec.name, sessions: sessions)
            groupIDs[spec.name] = group.id
            return group
        }
        let store = SessionStore(
            groups: groups,
            selectedSessionID: selectTag.flatMap { sessionIDs[$0] }
        )
        return (store, sessionIDs, groupIDs)
    }

    // MARK: - moveSession within group

    @Test("moveSession within group: 0 -> end reorders correctly")
    func moveSessionWithinGroupFirstToEnd() {
        let (store, sessionIDs, groupIDs) = makeStore(
            groupSpecs: [("g", ["a", "b", "c", "d"])]
        )

        store.moveSession(
            id: sessionIDs["a"]!,
            toGroupID: groupIDs["g"]!,
            atIndex: 3
        )

        #expect(store.groups[0].sessions.map { $0.title } == ["shell b", "shell c", "shell d", "shell a"])
    }

    @Test("moveSession within group: end -> 0 reorders correctly")
    func moveSessionWithinGroupEndToFirst() {
        let (store, sessionIDs, groupIDs) = makeStore(
            groupSpecs: [("g", ["a", "b", "c", "d"])]
        )

        store.moveSession(
            id: sessionIDs["d"]!,
            toGroupID: groupIDs["g"]!,
            atIndex: 0
        )

        #expect(store.groups[0].sessions.map { $0.title } == ["shell d", "shell a", "shell b", "shell c"])
    }

    @Test("moveSession within group: 1 -> 3 (drop-after-self) reorders correctly")
    func moveSessionWithinGroupOneToThree() {
        let (store, sessionIDs, groupIDs) = makeStore(
            groupSpecs: [("g", ["a", "b", "c", "d"])]
        )

        store.moveSession(
            id: sessionIDs["b"]!,
            toGroupID: groupIDs["g"]!,
            atIndex: 3
        )

        #expect(store.groups[0].sessions.map { $0.title } == ["shell a", "shell c", "shell d", "shell b"])
    }

    @Test("moveSession within group: 3 -> 1 (drop-before-self) reorders correctly")
    func moveSessionWithinGroupThreeToOne() {
        let (store, sessionIDs, groupIDs) = makeStore(
            groupSpecs: [("g", ["a", "b", "c", "d"])]
        )

        store.moveSession(
            id: sessionIDs["d"]!,
            toGroupID: groupIDs["g"]!,
            atIndex: 1
        )

        #expect(store.groups[0].sessions.map { $0.title } == ["shell a", "shell d", "shell b", "shell c"])
    }

    @Test("moveSession within group: drop on own position is a no-op")
    func moveSessionDropOnSelfIsNoOp() {
        let (store, sessionIDs, groupIDs) = makeStore(
            groupSpecs: [("g", ["a", "b", "c", "d"])]
        )
        let before = store.groups[0].sessions.map(\.id)

        store.moveSession(
            id: sessionIDs["b"]!,
            toGroupID: groupIDs["g"]!,
            atIndex: 1
        )

        #expect(store.groups[0].sessions.map(\.id) == before)
    }

    @Test("moveSession same-group source+1 is a REAL move, not a no-op — UI must guard self-drops")
    func moveSessionSamePlusOneIsRealMove() {
        // Documents the store contract: atIndex == sourceIndex + 1 in the
        // same group represents "move this workspace down by one" and the
        // store MUST mutate. UI callers that mean "drop on own row" have
        // to short-circuit before invoking moveSession (SidebarGroupView
        // does this via rowFrames[sourceID].contains(location)).
        let (store, sessionIDs, groupIDs) = makeStore(
            groupSpecs: [("g", ["a", "b", "c", "d"])]
        )

        store.moveSession(
            id: sessionIDs["b"]!,
            toGroupID: groupIDs["g"]!,
            atIndex: 2
        )

        #expect(store.groups[0].sessions.map { $0.title } == ["shell a", "shell c", "shell b", "shell d"])
    }

    @Test("moveGroup adjacent reorder (0→1) actually swaps — proves no spurious no-op")
    func moveGroupAdjacentReorder() {
        // Regression coverage for the adjacency case Codex flagged in
        // review: an asymmetric pre-removal target adjustment would
        // collide with moveGroup's same-position guard and silently
        // no-op a two-group sidebar's downward reorder.
        let (store, _, _) = makeStore(
            groupSpecs: [("g0", ["a"]), ("g1", ["b"])]
        )

        store.moveGroup(from: 0, to: 1)

        #expect(store.groups.map(\.name) == ["g1", "g0"])
    }

    @Test("moveSession clamps an out-of-range target index")
    func moveSessionClampsOutOfRange() {
        let (store, sessionIDs, groupIDs) = makeStore(
            groupSpecs: [("g", ["a", "b", "c"])]
        )

        store.moveSession(
            id: sessionIDs["a"]!,
            toGroupID: groupIDs["g"]!,
            atIndex: 999
        )

        #expect(store.groups[0].sessions.map { $0.title } == ["shell b", "shell c", "shell a"])
    }

    // MARK: - moveSession cross-group

    @Test("moveSession cross-group inserts at the target index")
    func moveSessionCrossGroup() {
        let (store, sessionIDs, groupIDs) = makeStore(
            groupSpecs: [
                ("src", ["a", "b"]),
                ("dst", ["x", "y", "z"]),
            ]
        )

        store.moveSession(
            id: sessionIDs["a"]!,
            toGroupID: groupIDs["dst"]!,
            atIndex: 1
        )

        #expect(store.groups[0].sessions.map { $0.title } == ["shell b"])
        #expect(store.groups[1].sessions.map { $0.title } == ["shell x", "shell a", "shell y", "shell z"])
    }

    @Test("moveSession cross-group preserves selection")
    func moveSessionCrossGroupPreservesSelection() {
        let (store, sessionIDs, groupIDs) = makeStore(
            groupSpecs: [
                ("src", ["a", "b"]),
                ("dst", ["x"]),
            ],
            selectTag: "a"
        )
        let aID = sessionIDs["a"]!

        store.moveSession(
            id: aID,
            toGroupID: groupIDs["dst"]!,
            atIndex: 0
        )

        #expect(store.selectedSessionID == aID)
        #expect(store.groups[1].sessions.map(\.id) == [aID, sessionIDs["x"]!])
    }

    @Test("moveSession into an empty group lands at index 0")
    func moveSessionIntoEmptyGroup() {
        let (store, sessionIDs, groupIDs) = makeStore(
            groupSpecs: [
                ("src", ["a", "b"]),
                ("empty", []),
            ]
        )

        store.moveSession(
            id: sessionIDs["a"]!,
            toGroupID: groupIDs["empty"]!,
            atIndex: 7
        )

        #expect(store.groups[1].sessions.map { $0.title } == ["shell a"])
    }

    @Test("moveSession of last workspace out leaves the source group empty but present")
    func moveSessionLastOutLeavesEmptyGroup() {
        let (store, sessionIDs, groupIDs) = makeStore(
            groupSpecs: [
                ("only", ["a"]),
                ("dst", ["x"]),
            ]
        )

        store.moveSession(
            id: sessionIDs["a"]!,
            toGroupID: groupIDs["dst"]!,
            atIndex: 0
        )

        #expect(store.groups.count == 2)
        #expect(store.groups[0].name == "only")
        #expect(store.groups[0].sessions.isEmpty)
        #expect(store.groups[1].sessions.count == 2)
    }

    @Test("moveSession with unknown session id is a no-op")
    func moveSessionUnknownSessionNoOp() {
        let (store, _, groupIDs) = makeStore(groupSpecs: [("g", ["a", "b"])])
        let before = store.groups[0].sessions.map(\.id)

        store.moveSession(
            id: TerminalSession.ID(),
            toGroupID: groupIDs["g"]!,
            atIndex: 0
        )

        #expect(store.groups[0].sessions.map(\.id) == before)
    }

    @Test("moveSession with unknown destination group is a no-op")
    func moveSessionUnknownGroupNoOp() {
        let (store, sessionIDs, _) = makeStore(groupSpecs: [("g", ["a", "b"])])
        let before = store.groups[0].sessions.map(\.id)

        store.moveSession(
            id: sessionIDs["a"]!,
            toGroupID: SessionGroup.ID(),
            atIndex: 0
        )

        #expect(store.groups[0].sessions.map(\.id) == before)
    }

    // MARK: - moveGroup

    @Test("moveGroup reorders top-level groups")
    func moveGroupReorders() {
        let (store, _, _) = makeStore(
            groupSpecs: [("g0", ["a"]), ("g1", ["b"]), ("g2", ["c"])]
        )

        store.moveGroup(from: 0, to: 2)

        #expect(store.groups.map(\.name) == ["g1", "g2", "g0"])
    }

    @Test("moveGroup same-position is a no-op")
    func moveGroupSamePositionNoOp() {
        let (store, _, _) = makeStore(
            groupSpecs: [("g0", ["a"]), ("g1", ["b"])]
        )

        store.moveGroup(from: 1, to: 1)

        #expect(store.groups.map(\.name) == ["g0", "g1"])
    }

    @Test("moveGroup clamps out-of-range target")
    func moveGroupClampsTarget() {
        let (store, _, _) = makeStore(
            groupSpecs: [("g0", ["a"]), ("g1", ["b"]), ("g2", ["c"])]
        )

        store.moveGroup(from: 0, to: 999)

        #expect(store.groups.map(\.name) == ["g1", "g2", "g0"])
    }

    @Test("moveGroup preserves selected workspace's group membership")
    func moveGroupPreservesSelection() {
        let (store, sessionIDs, _) = makeStore(
            groupSpecs: [("g0", ["a"]), ("g1", ["b"])],
            selectTag: "b"
        )
        let bID = sessionIDs["b"]!

        store.moveGroup(from: 1, to: 0)

        #expect(store.selectedSessionID == bID)
        #expect(store.groups[0].name == "g1")
    }

    @Test("moveGroup preserves group color with the moved group")
    func moveGroupPreservesColor() {
        let (store, _, groupIDs) = makeStore(
            groupSpecs: [("g0", ["a"]), ("g1", ["b"])]
        )

        #expect(store.setGroupColor(id: groupIDs["g1"]!, color: .sky))

        store.moveGroup(from: 1, to: 0)

        #expect(store.groups.map(\.name) == ["g1", "g0"])
        #expect(store.groups[0].color == .sky)
        #expect(store.groups[1].color == nil)
    }

    @Test("setGroupColor sets, clears, and rejects unknown groups")
    func setGroupColor() {
        let (store, _, groupIDs) = makeStore(
            groupSpecs: [("g0", ["a"])]
        )
        let groupID = groupIDs["g0"]!

        #expect(store.setGroupColor(id: groupID, color: .pink))
        #expect(store.groups[0].color == .pink)

        #expect(store.setGroupColor(id: groupID, color: nil))
        #expect(store.groups[0].color == nil)

        #expect(store.setGroupColor(id: SessionGroup.ID(), color: .teal) == false)
    }

    // MARK: - Persistence round-trip

    @Test("reorder survives a SessionSnapshot encode/decode round trip")
    func reorderSurvivesSnapshotRoundTrip() throws {
        let (store, sessionIDs, groupIDs) = makeStore(
            groupSpecs: [("g", ["a", "b", "c"]), ("h", ["x"])]
        )
        store.moveSession(id: sessionIDs["a"]!, toGroupID: groupIDs["g"]!, atIndex: 2)
        store.moveGroup(from: 0, to: 1)

        let snapshot = store.snapshot()
        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: encoded)
        let restored = SessionStore(restoring: decoded)

        #expect(restored.groups.map(\.name) == ["h", "g"])
        #expect(restored.groups[1].sessions.map { $0.title } == ["shell b", "shell c", "shell a"])
    }
}
