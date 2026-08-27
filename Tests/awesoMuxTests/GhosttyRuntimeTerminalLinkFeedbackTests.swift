import AwesoMuxCore
import Foundation
import Testing
@testable import awesoMux

@MainActor
@Suite("Terminal link open feedback", .serialized)
struct GhosttyRuntimeTerminalLinkFeedbackTests {
    @Test("missing relative Markdown click presents feedback and opens nothing")
    func missingRelativeMarkdownClickPresentsFeedback() async throws {
        GhosttyRuntime.resetTerminalLinkOpenFailurePresenterForTesting()
        defer { GhosttyRuntime.resetTerminalLinkOpenFailurePresenterForTesting() }

        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fixture = makeSurfaceFixture(workingDirectory: directory.path)
        defer { fixture.runtime.discardAllSurfaces() }
        var didPresentFromClickedView = false
        GhosttyRuntime.terminalLinkOpenFailurePresenter = {
            didPresentFromClickedView = $0 === fixture.view
        }

        await GhosttyRuntime.openURLAction(OpenURLAction("missing.md"), from: fixture.view)

        #expect(didPresentFromClickedView)
        #expect(fixture.store.session(id: fixture.session.id)?.layout.firstDocumentGroup == nil)
    }

    @Test("missing absolute Markdown click presents feedback and opens nothing")
    func missingAbsoluteMarkdownClickPresentsFeedback() async {
        GhosttyRuntime.resetTerminalLinkOpenFailurePresenterForTesting()
        defer { GhosttyRuntime.resetTerminalLinkOpenFailurePresenterForTesting() }

        let path = FileManager.default.temporaryDirectory
            .appending(path: "missing-\(UUID().uuidString).md")
            .path
        #expect(OpenURLAction.resolve(path) == nil)

        let fixture = makeSurfaceFixture(workingDirectory: "/tmp")
        defer { fixture.runtime.discardAllSurfaces() }
        var didPresent = false
        GhosttyRuntime.terminalLinkOpenFailurePresenter = { _ in didPresent = true }

        await GhosttyRuntime.openURLAction(OpenURLAction(path), from: fixture.view)

        #expect(didPresent)
        #expect(fixture.store.session(id: fixture.session.id)?.layout.firstDocumentGroup == nil)
    }

    @Test("missing home-relative Markdown click presents feedback and opens nothing")
    func missingHomeRelativeMarkdownClickPresentsFeedback() async {
        GhosttyRuntime.resetTerminalLinkOpenFailurePresenterForTesting()
        defer { GhosttyRuntime.resetTerminalLinkOpenFailurePresenterForTesting() }

        let path = "~/.awesomux-missing-\(UUID().uuidString).md"
        #expect(OpenURLAction.resolve(path) == nil)

        let fixture = makeSurfaceFixture(workingDirectory: "/tmp")
        defer { fixture.runtime.discardAllSurfaces() }
        var didPresent = false
        GhosttyRuntime.terminalLinkOpenFailurePresenter = { _ in didPresent = true }

        await GhosttyRuntime.openURLAction(OpenURLAction(path), from: fixture.view)

        #expect(didPresent)
        #expect(fixture.store.session(id: fixture.session.id)?.layout.firstDocumentGroup == nil)
    }

    @Test("non-Markdown terminal click stays blocked and presents feedback")
    func nonMarkdownClickStaysBlockedAndPresentsFeedback() async throws {
        GhosttyRuntime.resetTerminalLinkOpenFailurePresenterForTesting()
        defer { GhosttyRuntime.resetTerminalLinkOpenFailurePresenterForTesting() }

        let fixture = makeSurfaceFixture(workingDirectory: "/tmp")
        defer { fixture.runtime.discardAllSurfaces() }
        var didPresent = false
        GhosttyRuntime.terminalLinkOpenFailurePresenter = { _ in didPresent = true }

        await GhosttyRuntime.openURLAction(OpenURLAction("/tmp/run.sh"), from: fixture.view)

        #expect(didPresent)
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

    @Test("rejected recent terminal link presents the same feedback")
    func rejectedRecentLinkPresentsFeedback() async {
        GhosttyRuntime.resetTerminalLinkOpenFailurePresenterForTesting()
        defer { GhosttyRuntime.resetTerminalLinkOpenFailurePresenterForTesting() }

        let fixture = makeSurfaceFixture(workingDirectory: "/tmp")
        defer { fixture.runtime.discardAllSurfaces() }
        var didPresentWithoutSurface = false
        GhosttyRuntime.terminalLinkOpenFailurePresenter = {
            didPresentWithoutSurface = $0 == nil
        }

        await GhosttyRuntime.openRecentLink(
            "/tmp/run.sh",
            in: fixture.session.id,
            associatedWith: fixture.view.paneID,
            sessionStore: fixture.store
        )

        #expect(didPresentWithoutSurface)
        #expect(fixture.store.session(id: fixture.session.id)?.layout.firstDocumentGroup == nil)
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
