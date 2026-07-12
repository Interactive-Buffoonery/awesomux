import Foundation
import Testing
@testable import AwesoMuxCore

@MainActor
@Suite("Pop-up terminal store factory")
struct PopUpTerminalStoreFactoryTests {
    @Test("first creation inherits a valid selected workspace directory")
    func inheritsSelectedWorkspaceDirectory() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("awesomux-popup-factory-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let directory = directoryURL.resolvingSymlinksInPath().path
        let workspace = TerminalSession(title: "repo", workingDirectory: directory)

        let store = PopUpTerminalStoreFactory.makeStore(
            selectedWorkspace: workspace,
            fallbackHome: WorkingDirectoryValidator.canonicalHomeDirectory
        )

        let session = try #require(store.selectedSession)
        let group = try #require(store.groups.first)
        #expect(session.title == "terminal companion")
        #expect(session.workingDirectory == directory)
        #expect(session.layout.paneIDs.count == 1)
        #expect(store.groups.count == 1)
        #expect(group.sessions.count == 1)
        #expect(group.sessions.first?.id == session.id)
        #expect(store.compactTerminalKind == .popUpTerminal)
    }

    @Test("invalid selected directory falls back to canonical home")
    func invalidDirectoryFallsBack() throws {
        let workspace = TerminalSession(
            title: "missing",
            workingDirectory: "/definitely/missing/awesomux-popup-terminal"
        )

        let store = PopUpTerminalStoreFactory.makeStore(
            selectedWorkspace: workspace,
            fallbackHome: "~"
        )

        #expect(
            try #require(store.selectedSession).workingDirectory
                == WorkingDirectoryValidator.canonicalHomeDirectory
        )
    }

    @Test("invalid selected and fallback directories use canonical home")
    func invalidCandidatesUseCanonicalHome() throws {
        let workspace = TerminalSession(
            title: "missing",
            workingDirectory: "/definitely/missing/awesomux-popup-selected"
        )

        let store = PopUpTerminalStoreFactory.makeStore(
            selectedWorkspace: workspace,
            fallbackHome: "/definitely/missing/awesomux-popup-fallback"
        )

        #expect(
            try #require(store.selectedSession).workingDirectory
                == WorkingDirectoryValidator.canonicalHomeDirectory
        )
    }
}
