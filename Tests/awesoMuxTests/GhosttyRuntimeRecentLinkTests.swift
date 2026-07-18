import AwesoMuxCore
import Foundation
import Testing
@testable import awesoMux

@MainActor
@Suite("Recent terminal link routing", .serialized)
struct GhosttyRuntimeRecentLinkTests {
    @Test func relativeMarkdownUsesCapturedPaneCurrentWorkingDirectory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "docs/readme.md")
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("# Test".utf8).write(to: fileURL)

        let (store, session, pane) = makeStore(workingDirectory: directory.path)
        await GhosttyRuntime.openRecentLink(
            "docs/readme.md",
            in: session.id,
            associatedWith: pane.id,
            sessionStore: store
        )
        #expect(store.session(id: session.id)?.layout.firstDocumentGroup?.selectedTab?.fileURL == fileURL)
    }

    @Test func missingCapturedPaneFailsClosed() async {
        let (store, session, _) = makeStore(workingDirectory: "/tmp")
        await GhosttyRuntime.openRecentLink(
            "readme.md",
            in: session.id,
            associatedWith: TerminalPane.ID(),
            sessionStore: store
        )
        #expect(store.session(id: session.id)?.layout.firstDocumentGroup == nil)
    }

    @Test func absoluteAndTildeMarkdownUseExistingResolutionGate() async {
        let (store, session, pane) = makeStore(workingDirectory: "/tmp")
        var routed: [URL] = []
        GhosttyRuntime.setOpenDocumentHandler { routed.append($0) }
        defer { GhosttyRuntime.setOpenDocumentHandler(nil) }

        await GhosttyRuntime.openRecentLink(
            "/tmp/readme.md",
            in: session.id,
            associatedWith: pane.id,
            sessionStore: store
        )
        await GhosttyRuntime.openRecentLink(
            "~/readme.md",
            in: session.id,
            associatedWith: pane.id,
            sessionStore: store
        )
        await GhosttyRuntime.openRecentLink(
            "/tmp/run.sh",
            in: session.id,
            associatedWith: pane.id,
            sessionStore: store
        )
        #expect(routed.count == 2)
        #expect(routed.allSatisfy { $0.pathExtension == "md" })
    }

    @Test func unsupportedSchemeFailsClosed() async {
        let (store, session, pane) = makeStore(workingDirectory: "/tmp")
        var routed: [URL] = []
        GhosttyRuntime.setOpenDocumentHandler { routed.append($0) }
        defer { GhosttyRuntime.setOpenDocumentHandler(nil) }

        await GhosttyRuntime.openRecentLink(
            "javascript:alert(1)",
            in: session.id,
            associatedWith: pane.id,
            sessionStore: store
        )
        #expect(routed.isEmpty)
        #expect(store.session(id: session.id)?.layout.firstDocumentGroup == nil)
    }

    @Test func remoteMarkdownUsesCapturedPaneRoutingContext() async throws {
        GhosttyRuntime.resetRecentLinkRemoteSnapshotProviderForTesting()
        defer { GhosttyRuntime.resetRecentLinkRemoteSnapshotProviderForTesting() }
        let target = try #require(RemoteTarget(parsing: "deploy@example.com"))
        let pane = TerminalPane(
            title: "remote",
            workingDirectory: "/local",
            remoteWorkingDirectory: "/srv/project",
            executionPlan: .ssh(.init(target: target))
        )
        let session = makeSession(pane)
        let store = makeStore(session)
        var captured: RemoteMarkdownReference?
        GhosttyRuntime.recentLinkRemoteSnapshotProvider = { reference in
            captured = reference
            return nil
        }

        await GhosttyRuntime.openRecentLink(
            "docs/readme.md",
            in: session.id,
            associatedWith: pane.id,
            sessionStore: store
        )
        #expect(captured?.identity.location == .remote(target))
        #expect(captured?.identity.path.rawValue == "/srv/project/docs/readme.md")
    }

    @Test func remoteMarkdownLineReferenceNeverFallsThroughToSameNamedLocalFile() async throws {
        GhosttyRuntime.resetRecentLinkRemoteSnapshotProviderForTesting()
        defer { GhosttyRuntime.resetRecentLinkRemoteSnapshotProviderForTesting() }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("# Local impostor".utf8).write(to: directory.appending(path: "README.md"))

        let target = try #require(RemoteTarget(parsing: "deploy@example.com"))
        let pane = TerminalPane(
            title: "remote",
            workingDirectory: directory.path,
            remoteWorkingDirectory: "/srv/project",
            executionPlan: .ssh(.init(target: target))
        )
        let session = makeSession(pane)
        let store = makeStore(session)
        var captured: RemoteMarkdownReference?
        GhosttyRuntime.recentLinkRemoteSnapshotProvider = { reference in
            captured = reference
            return nil
        }

        await GhosttyRuntime.openRecentLink(
            "README.md:12",
            in: session.id,
            associatedWith: pane.id,
            sessionStore: store
        )

        #expect(captured?.identity.location == .remote(target))
        #expect(captured?.identity.path.rawValue == "/srv/project/README.md")
        #expect(store.session(id: session.id)?.layout.firstDocumentGroup == nil)
    }

    @Test func unresolvedRemoteMarkdownPresentsRoutingFailure() async throws {
        GhosttyRuntime.resetRemoteMarkdownRoutingFailurePresenterForTesting()
        defer { GhosttyRuntime.resetRemoteMarkdownRoutingFailurePresenterForTesting() }
        let target = try #require(RemoteTarget(parsing: "deploy@example.com"))
        let pane = TerminalPane(
            title: "remote",
            workingDirectory: "/local",
            remoteWorkingDirectory: nil,
            executionPlan: .ssh(.init(target: target))
        )
        let session = makeSession(pane)
        let store = makeStore(session)
        var didPresent = false
        GhosttyRuntime.remoteMarkdownRoutingFailurePresenter = { view in
            #expect(view == nil)
            didPresent = true
        }

        await GhosttyRuntime.openRecentLink(
            "docs/readme.md",
            in: session.id,
            associatedWith: pane.id,
            sessionStore: store
        )

        #expect(didPresent)
    }

    private func makeStore(
        workingDirectory: String
    ) -> (SessionStore, TerminalSession, TerminalPane) {
        let pane = TerminalPane(
            title: "pane",
            workingDirectory: workingDirectory,
            executionPlan: .local
        )
        let session = makeSession(pane)
        return (makeStore(session), session, pane)
    }

    private func makeSession(_ pane: TerminalPane) -> TerminalSession {
        TerminalSession(
            title: "session",
            workingDirectory: pane.workingDirectory,
            layout: .pane(pane),
            activePaneID: pane.id
        )
    }

    private func makeStore(_ session: TerminalSession) -> SessionStore {
        SessionStore(
            groups: [SessionGroup(name: "group", sessions: [session])],
            selectedSessionID: session.id
        )
    }
}
