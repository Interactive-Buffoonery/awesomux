import Foundation
import Testing
@testable import AwesoMuxCore

@Suite("WorkspaceTreeReducer")
struct WorkspaceTreeReducerTests {
    @Test("addSession routes invisible names to the canonical group")
    func addSessionRoutesInvisibleNamesToCanonicalGroup() throws {
        var groups: [SessionGroup] = []

        let firstID = WorkspaceTreeReducer.addSession(
            to: &groups,
            selectedSession: nil,
            title: nil,
            workingDirectory: nil,
            agentKind: .shell,
            groupName: "\u{200B}"
        )
        let secondID = WorkspaceTreeReducer.addSession(
            to: &groups,
            selectedSession: groups[0].sessions[0],
            title: nil,
            workingDirectory: nil,
            agentKind: .shell,
            groupName: "\u{202E}"
        )

        #expect(groups.map(\.name) == ["awesoMux"])
        #expect(groups[0].sessions.map(\.id) == [firstID, secondID])
        #expect(groups[0].sessions.map(\.title) == ["shell 1", "shell 2"])
        #expect(
            groups[0].sessions.map(\.syntheticTitle) == [
                SyntheticSessionTitle(agentKind: .shell, index: 1),
                SyntheticSessionTitle(agentKind: .shell, index: 2),
            ])
    }

    @Test("explicit session titles do not gain synthetic metadata")
    func explicitSessionTitleHasNoSyntheticMetadata() {
        var groups: [SessionGroup] = []

        _ = WorkspaceTreeReducer.addSession(
            to: &groups,
            selectedSession: nil,
            title: "release",
            workingDirectory: nil,
            agentKind: .shell,
            groupName: "awesoMux"
        )

        #expect(groups[0].sessions[0].title == "release")
        #expect(groups[0].sessions[0].syntheticTitle == nil)
    }

    @Test("synthetic metadata reserves its index independently of the stored display string")
    func syntheticMetadataReservesIndex() {
        let localizedLegacy = TerminalSession(
            title: "⟦1:⟦shell⟧⟧",
            workingDirectory: "~",
            syntheticTitle: SyntheticSessionTitle(agentKind: .shell, index: 1),
            agentKind: .shell
        )
        var groups = [SessionGroup(name: "awesoMux", sessions: [localizedLegacy])]

        let id = WorkspaceTreeReducer.addSession(
            to: &groups,
            selectedSession: localizedLegacy,
            title: nil,
            workingDirectory: nil,
            agentKind: .shell,
            groupName: "awesoMux"
        )

        let added = groups[0].sessions.first { $0.id == id }
        #expect(added?.syntheticTitle == SyntheticSessionTitle(agentKind: .shell, index: 2))
        #expect(added?.title == "shell 2")
    }

    @Test("canonical titles reserve their index across locale changes")
    func canonicalTitleCollisionReservesIndex() {
        let manuallyNamed = TerminalSession(
            title: "shell 2",
            workingDirectory: "~",
            isTitleUserEdited: true,
            agentKind: .shell
        )
        let groups = [SessionGroup(name: "awesoMux", sessions: [manuallyNamed])]

        let generated = WorkspaceTreeReducer.nextSyntheticSessionTitle(
            in: groups,
            for: .shell
        )

        #expect(generated.index == 3)
    }

    @Test("insertSession appends a promoted session into its target group")
    func insertSessionAppendsIntoTargetGroup() throws {
        let existing = TerminalSession(title: "existing", workingDirectory: "~", agentKind: .shell)
        var groups = [SessionGroup(name: "awesoMux", sessions: [existing])]
        let promoted = TerminalSession(title: "promoted", workingDirectory: "~", agentKind: .shell)

        WorkspaceTreeReducer.insertSession(promoted, into: &groups, groupName: "awesoMux")

        #expect(groups.count == 1)
        #expect(groups[0].sessions.map(\.id) == [existing.id, promoted.id])
    }

    @Test("insertSession refuses a session whose ID already lives in the tree")
    func insertSessionRefusesDuplicateID() throws {
        let session = TerminalSession(title: "promoted", workingDirectory: "~", agentKind: .shell)
        var groups = [SessionGroup(name: "awesoMux", sessions: [session])]

        WorkspaceTreeReducer.insertSession(session, into: &groups, groupName: "awesoMux")
        WorkspaceTreeReducer.insertSession(session, into: &groups, groupName: "other")

        #expect(groups.count == 1)
        #expect(groups[0].sessions.map(\.id) == [session.id])
    }

    @Test("selection offsets wrap across groups and skip empty groups")
    func selectionOffsetsWrapAcrossGroups() throws {
        let first = TerminalSession(title: "first", workingDirectory: "~", agentKind: .shell)
        let second = TerminalSession(title: "second", workingDirectory: "~", agentKind: .shell)
        let third = TerminalSession(title: "third", workingDirectory: "~", agentKind: .shell)
        let groups = [
            SessionGroup(name: "one", sessions: [first]),
            SessionGroup(name: "empty", sessions: []),
            SessionGroup(name: "two", sessions: [second, third]),
        ]
        let index = SessionStoreIndex.build(from: groups)

        #expect(
            WorkspaceTreeReducer.selectedSessionID(
                in: groups,
                index: index,
                currentSelection: first.id,
                offset: -1
            ) == third.id)
        #expect(
            WorkspaceTreeReducer.selectedSessionID(
                in: groups,
                index: index,
                currentSelection: first.id,
                offset: 2
            ) == third.id)
    }
}
