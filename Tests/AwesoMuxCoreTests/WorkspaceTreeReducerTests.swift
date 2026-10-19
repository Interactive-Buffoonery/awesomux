import Foundation
import Testing
@testable import AwesoMuxCore

@Suite("WorkspaceTreeReducer")
struct WorkspaceTreeReducerTests {

    @Test("insertSession refuses a session whose ID already lives in the tree")
    func insertSessionRefusesDuplicateID() throws {
        let session = TerminalSession(title: "promoted", workingDirectory: "~", agentKind: .shell)
        var groups = [SessionGroup(name: "awesoMux", sessions: [session])]

        WorkspaceTreeReducer.insertSession(session, into: &groups, groupName: "awesoMux")
        WorkspaceTreeReducer.insertSession(session, into: &groups, groupName: "other")

        #expect(groups.count == 1)
        #expect(groups[0].sessions.map(\.id) == [session.id])
    }

    @Test("insertSession after source places, refuses duplicates, and requires source")
    func insertSessionAfterSource() {
        let source = TerminalSession(title: "source", workingDirectory: "~")
        let tail = TerminalSession(title: "tail", workingDirectory: "~")
        let inserted = TerminalSession(title: "inserted", workingDirectory: "~")
        var groups = [SessionGroup(name: "work", sessions: [source, tail])]

        #expect(WorkspaceTreeReducer.insertSession(inserted, after: source.id, into: &groups))
        #expect(groups[0].sessions.map(\.id) == [source.id, inserted.id, tail.id])
        #expect(!WorkspaceTreeReducer.insertSession(inserted, after: source.id, into: &groups))
        #expect(
            !WorkspaceTreeReducer.insertSession(
                TerminalSession(title: "missing", workingDirectory: "~"),
                after: UUID(),
                into: &groups
            ))
    }

}
