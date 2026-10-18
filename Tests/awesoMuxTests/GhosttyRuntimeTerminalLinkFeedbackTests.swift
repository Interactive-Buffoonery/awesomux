import AwesoMuxCore
import AwesoMuxTestSupport
import Foundation
import Testing
@testable import awesoMux

@MainActor
@Suite("Terminal link open feedback", .serialized)
struct GhosttyRuntimeTerminalLinkFeedbackTests {
    @Test(arguments: ["relative", "absolute", "home", "non-markdown", "recent"])
    func rejectedLinkPresentsFeedback(kind: String) async throws {
        GhosttyRuntime.resetTerminalLinkOpenFailurePresenterForTesting()
        defer { GhosttyRuntime.resetTerminalLinkOpenFailurePresenterForTesting() }
        let directory = try TemporaryDirectory(prefix: "terminal-link-feedback")
        defer { withExtendedLifetime(directory) {} }
        let fixture = makeSurfaceFixture(workingDirectory: kind == "relative" ? directory.url.path : "/tmp")
        defer { fixture.runtime.discardAllSurfaces() }
        let path: String
        switch kind {
        case "relative": path = "missing.md"
        case "absolute": path = directory.url.appending(path: "missing.md").path
        case "home": path = "~/.awesomux-missing-\(UUID().uuidString).md"
        default: path = "/tmp/run.sh"
        }
        if ["absolute", "home"].contains(kind) { #expect(OpenURLAction.resolve(path) == nil) }
        var presented = false
        GhosttyRuntime.terminalLinkOpenFailurePresenter = { view in
            #expect(kind == "recent" ? view == nil : view === fixture.view)
            presented = true
        }
        if kind == "recent" {
            await GhosttyRuntime.openRecentLink(
                path, in: fixture.session.id, associatedWith: fixture.view.paneID, sessionStore: fixture.store)
        } else {
            await GhosttyRuntime.openURLAction(OpenURLAction(path), from: fixture.view)
        }
        #expect(presented)
        #expect(fixture.store.session(id: fixture.session.id)?.layout.firstDocumentGroup == nil)
    }

    @Test("existing relative Markdown click opens without failure feedback")
    func existingRelativeMarkdownClickOpensWithoutFeedback() async throws {
        GhosttyRuntime.resetTerminalLinkOpenFailurePresenterForTesting()
        defer { GhosttyRuntime.resetTerminalLinkOpenFailurePresenterForTesting() }

        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "notes.md")
        try Data("# Notes".utf8).write(to: fileURL)

        let fixture = makeSurfaceFixture(workingDirectory: directory.path)
        defer { fixture.runtime.discardAllSurfaces() }
        var didPresent = false
        GhosttyRuntime.terminalLinkOpenFailurePresenter = { _ in didPresent = true }

        await GhosttyRuntime.openURLAction(OpenURLAction("notes.md"), from: fixture.view)

        #expect(!didPresent)
        #expect(
            fixture.store.session(id: fixture.session.id)?.layout.firstDocumentGroup?.selectedTab?.fileURL
                == fileURL
        )
    }

    private func makeSurfaceFixture(workingDirectory: String) -> SurfaceFixture {
        let pane = TerminalPane(
            title: "pane",
            workingDirectory: workingDirectory,
            executionPlan: .local
        )
        let session = TerminalSession(
            title: "workspace",
            workingDirectory: workingDirectory,
            layout: .pane(pane),
            activePaneID: pane.id
        )
        let store = SessionStore(
            groups: [SessionGroup(name: "group", sessions: [session])],
            selectedSessionID: session.id
        )
        let runtime = GhosttyRuntime(initialCommandBridgeEnabled: true)
        let view = runtime.surfaceView(
            sessionStore: store,
            session: session,
            pane: pane,
            enabledAgentRuntimeFileDropSources: [],
            grokIconEnabled: false
        )
        return SurfaceFixture(runtime: runtime, store: store, session: session, view: view)
    }

    private struct SurfaceFixture {
        let runtime: GhosttyRuntime
        let store: SessionStore
        let session: TerminalSession
        let view: GhosttySurfaceNSView
    }
}
