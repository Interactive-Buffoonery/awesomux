import Foundation
import Testing
@testable import AwesoMuxCore

@Suite("WorkspaceTreeReducer group operations")
struct WorkspaceTreeReducerGroupTests {
    @Test("renameGroup rejects empty-after-sanitization names")
    func renameGroupRejectsEmptyName() {
        var groups = [SessionGroup(name: "main", sessions: [])]
        #expect(!WorkspaceTreeReducer.renameGroup(in: &groups, id: groups[0].id, to: "\u{200B}"))
        #expect(groups[0].name == "main")
    }

    @Test("renameGroup rejects duplicate names")
    func renameGroupRejectsDuplicateName() {
        var groups = [
            SessionGroup(name: "main", sessions: []),
            SessionGroup(name: "scratch", sessions: [])
        ]
        #expect(!WorkspaceTreeReducer.renameGroup(in: &groups, id: groups[0].id, to: "scratch"))
        #expect(groups[0].name == "main")
    }

    @Test("renameGroup no-ops and returns true for same name")
    func renameGroupNoOpsForSameName() {
        var groups = [SessionGroup(name: "main", sessions: [])]
        #expect(WorkspaceTreeReducer.renameGroup(in: &groups, id: groups[0].id, to: "main"))
        #expect(groups[0].name == "main")
    }

    @Test("renameGroup applies sanitized name")
    func renameGroupAppliesSanitizedName() {
        var groups = [SessionGroup(name: "main", sessions: [])]
        #expect(WorkspaceTreeReducer.renameGroup(in: &groups, id: groups[0].id, to: "  new  "))
        #expect(groups[0].name == "new")
    }

    @Test("renameGroup returns false for nonexistent group")
    func renameGroupReturnsFalseForMissingID() {
        var groups = [SessionGroup(name: "main", sessions: [])]
        #expect(!WorkspaceTreeReducer.renameGroup(in: &groups, id: UUID(), to: "other"))
    }

    @Test("setGroupColor updates and returns true")
    func setGroupColorUpdates() {
        var groups = [SessionGroup(name: "main", sessions: [])]
        #expect(WorkspaceTreeReducer.setGroupColor(in: &groups, id: groups[0].id, color: WorkspaceGroupColor.mauve))
        #expect(groups[0].color == WorkspaceGroupColor.mauve)
    }

    @Test("setGroupColor accepts requested INT-288 palette colors")
    func setGroupColorAcceptsRequestedPaletteColors() {
        var groups = [SessionGroup(name: "main", sessions: [])]

        for color in WorkspaceGroupColor.pickerCases {
            #expect(WorkspaceTreeReducer.setGroupColor(in: &groups, id: groups[0].id, color: color))
            #expect(groups[0].color == color)
        }
    }

    @Test("setGroupColor returns false for nonexistent group")
    func setGroupColorReturnsFalseForMissingID() {
        var groups = [SessionGroup(name: "main", sessions: [])]
        #expect(!WorkspaceTreeReducer.setGroupColor(in: &groups, id: UUID(), color: WorkspaceGroupColor.mauve))
    }

    @Test("setGroupColor no-ops and returns true for same color")
    func setGroupColorNoOpsForSameColor() {
        var groups = [SessionGroup(name: "main", color: WorkspaceGroupColor.mauve, sessions: [])]
        #expect(WorkspaceTreeReducer.setGroupColor(in: &groups, id: groups[0].id, color: WorkspaceGroupColor.mauve))
        #expect(groups[0].color == WorkspaceGroupColor.mauve)
    }

    @Test("group color picker cases match INT-288 menu contract")
    func groupColorPickerCasesMatchIssueContract() {
        #expect(WorkspaceGroupColor.pickerCases == [
            .mauve, .peach, .green, .teal, .blue, .pink, .yellow, .red, .gray,
        ])
        #expect(!WorkspaceGroupColor.pickerCases.contains(.sky))
        #expect(!WorkspaceGroupColor.pickerCases.contains(.lavender))
    }

    @Test("containsGroup finds existing group case-insensitively")
    func containsGroupFindsExisting() {
        let groups = [SessionGroup(name: "Main", sessions: [])]
        #expect(WorkspaceTreeReducer.containsGroup(in: groups, named: "main"))
        #expect(WorkspaceTreeReducer.containsGroup(in: groups, named: "MAIN"))
    }

    @Test("containsGroup rejects empty-after-sanitization name")
    func containsGroupRejectsEmptyName() {
        let groups = [SessionGroup(name: "main", sessions: [])]
        #expect(!WorkspaceTreeReducer.containsGroup(in: groups, named: "\u{200B}"))
    }

    @Test("removeGroup removes empty non-last group")
    func removeGroupRemovesEmptyGroup() {
        var groups = [
            SessionGroup(name: "main", sessions: []),
            SessionGroup(name: "scratch", sessions: [])
        ]
        #expect(WorkspaceTreeReducer.removeGroup(in: &groups, id: groups[1].id))
        #expect(groups.count == 1)
        #expect(groups[0].name == "main")
    }

    @Test("removeGroup rejects last group")
    func removeGroupRejectsLastGroup() {
        var groups = [SessionGroup(name: "main", sessions: [])]
        #expect(!WorkspaceTreeReducer.removeGroup(in: &groups, id: groups[0].id))
    }

    @Test("removeGroup rejects group with sessions")
    func removeGroupRejectsNonEmptyGroup() {
        let session = TerminalSession(title: "shell", workingDirectory: "~", agentKind: .shell)
        var groups = [
            SessionGroup(name: "main", sessions: [session]),
            SessionGroup(name: "scratch", sessions: [])
        ]
        #expect(!WorkspaceTreeReducer.removeGroup(in: &groups, id: groups[0].id))
    }

    @Test("addWorkspaceGroup creates new group with session")
    func addWorkspaceGroupCreatesGroup() {
        var groups: [SessionGroup] = []
        let id = WorkspaceTreeReducer.addWorkspaceGroup(
            to: &groups,
            selectedSession: nil,
            named: "scratch",
            workingDirectory: nil,
            agentKind: .shell
        )
        #expect(id != nil)
        #expect(groups.count == 1)
        #expect(groups[0].name == "scratch")
        #expect(groups[0].sessions.count == 1)
    }

    @Test("addWorkspaceGroup rejects duplicate name")
    func addWorkspaceGroupRejectsDuplicate() {
        var groups = [SessionGroup(name: "scratch", sessions: [])]
        let id = WorkspaceTreeReducer.addWorkspaceGroup(
            to: &groups,
            selectedSession: nil,
            named: "scratch",
            workingDirectory: nil,
            agentKind: .shell
        )
        #expect(id == nil)
        #expect(groups.count == 1)
    }

    @Test("addWorkspaceGroup rejects empty-after-sanitization name")
    func addWorkspaceGroupRejectsEmptyName() {
        var groups: [SessionGroup] = []
        let id = WorkspaceTreeReducer.addWorkspaceGroup(
            to: &groups,
            selectedSession: nil,
            named: "\u{200B}",
            workingDirectory: nil,
            agentKind: .shell
        )
        #expect(id == nil)
        #expect(groups.isEmpty)
    }

    @Test("addWorkspaceGroup carries remote target when provided")
    func addWorkspaceGroupCarriesRemoteTarget() {
        var groups: [SessionGroup] = []
        let target = RemoteTarget(user: "ed", host: "box")!
        let seeded = WorkspaceTreeReducer.addWorkspaceGroup(
            to: &groups,
            selectedSession: nil,
            named: "box",
            workingDirectory: nil,
            agentKind: .shell,
            remote: target
        )
        #expect(seeded != nil)
        #expect(groups.last?.remote == target)
        #expect(groups.last?.sessions.count == 1)
    }
}
