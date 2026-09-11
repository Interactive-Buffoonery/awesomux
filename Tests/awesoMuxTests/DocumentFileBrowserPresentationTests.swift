import AwesoMuxCore
import Foundation
import Testing
@testable import awesoMux

@Suite("Document file browser presentation")
@MainActor
struct DocumentFileBrowserPresentationTests {
    @Test("browser-only roots keep association fallback local and reject remote sources")
    func browserOnlyRootUsesEffectiveLocalSource() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentFileBrowserPresentationTests-\(UUID().uuidString)")
        let sourceURL = root.appendingPathComponent("source", isDirectory: true)
        let activeURL = root.appendingPathComponent("active", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: activeURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = TerminalPane(title: "source", workingDirectory: sourceURL.path, executionPlan: .local)
        let active = TerminalPane(title: "active", workingDirectory: activeURL.path, executionPlan: .local)
        let layout = TerminalPaneLayout.split(
            TerminalSplit(
                orientation: .vertical,
                first: .pane(source),
                second: .pane(active)
            ))
        let session = TerminalSession(
            title: "Main",
            workingDirectory: root.path,
            layout: layout,
            activePaneID: active.id
        )

        #expect(
            DocumentFileBrowserPaneView.rootURL(in: session, associatedWith: source.id)
                == sourceURL
        )
        #expect(
            DocumentFileBrowserPaneView.rootURL(
                in: session,
                associatedWith: TerminalPane.ID()
            ) == activeURL
        )

        let remote = TerminalPane(
            title: "remote",
            workingDirectory: "/stale",
            executionPlan: .ssh(SSHExecution(target: try #require(RemoteTarget(user: "eD", host: "remote.example"))))
        )
        let remoteSession = TerminalSession(
            title: "Remote",
            workingDirectory: root.path,
            layout: .split(
                TerminalSplit(
                    orientation: .vertical,
                    first: .pane(remote),
                    second: .pane(active)
                )),
            activePaneID: active.id
        )
        #expect(DocumentFileBrowserPaneView.rootURL(in: remoteSession, associatedWith: remote.id) == nil)

        let invalidLocalSource = TerminalPane(
            title: "invalid local",
            workingDirectory: "/missing-local-source",
            executionPlan: .local
        )
        let unsafeFallbackSession = TerminalSession(
            title: "Unsafe fallback",
            workingDirectory: root.path,
            layout: .split(
                TerminalSplit(
                    orientation: .vertical,
                    first: .pane(invalidLocalSource),
                    second: .pane(remote)
                )),
            activePaneID: remote.id
        )
        #expect(
            DocumentFileBrowserPaneView.rootURL(
                in: unsafeFallbackSession,
                associatedWith: invalidLocalSource.id
            ) == nil
        )

        #expect(
            DocumentFileBrowserPaneView.closeFocusPaneID(
                in: session,
                preferredSourcePaneID: source.id
            ) == source.id
        )
        #expect(
            DocumentFileBrowserPaneView.closeFocusPaneID(
                in: session,
                preferredSourcePaneID: TerminalPane.ID()
            ) == active.id
        )
    }
}
