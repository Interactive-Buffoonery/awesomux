import AwesoMuxCore
import Foundation
import Testing

@testable import awesoMux

@Suite("Document pane content identity")
struct DocumentPaneContentIdentityTests {
    @Test("remote tabs remount on tab id; local tabs remount on file path")
    func remountID() {
        let remoteID = UUID()
        let remote = DocumentPane(
            id: remoteID,
            fileURL: URL(fileURLWithPath: "/tmp/cache.md"),
            title: "cache.md",
            remoteResourceIdentity: ResourceIdentity(
                location: .remote(RemoteTarget(parsing: "devbox")!),
                path: ResourcePath(rawValue: "/repo/doc.md")
            )
        )
        let remoteFailureSlot = DocumentPane(
            id: remoteID,
            fileURL: URL(fileURLWithPath: "/tmp/cache.failure.md"),
            title: "cache.failure.md",
            remoteResourceIdentity: remote.remoteResourceIdentity
        )
        #expect(
            DocumentPaneContentIdentity.remountID(for: remote)
                == DocumentPaneContentIdentity.remountID(for: remoteFailureSlot))
        #expect(DocumentPaneContentIdentity.remountID(for: remote).hasPrefix("remote-tab:"))

        let local = DocumentPane(
            fileURL: URL(fileURLWithPath: "/tmp/notes.md"),
            title: "notes.md"
        )
        let localOther = DocumentPane(
            id: local.id,
            fileURL: URL(fileURLWithPath: "/tmp/other.md"),
            title: "other.md"
        )
        #expect(
            DocumentPaneContentIdentity.remountID(for: local)
                == URL(fileURLWithPath: "/tmp/notes.md").standardizedFileURL.path)
        #expect(
            DocumentPaneContentIdentity.remountID(for: local)
                != DocumentPaneContentIdentity.remountID(for: localOther))
    }

    @Test("same remote identity suppresses Now showing; local and retarget do not")
    func nowShowingPolicy() {
        let identity = ResourceIdentity(
            location: .remote(RemoteTarget(parsing: "devbox")!),
            path: ResourcePath(rawValue: "/repo/doc.md")
        )
        let other = ResourceIdentity(
            location: .remote(RemoteTarget(parsing: "devbox")!),
            path: ResourcePath(rawValue: "/repo/other.md")
        )

        #expect(
            !DocumentShownAnnouncementPolicy.shouldAnnounceNowShowing(
                previousRemoteIdentity: identity,
                currentRemoteIdentity: identity
            ))
        #expect(
            DocumentShownAnnouncementPolicy.shouldAnnounceNowShowing(
                previousRemoteIdentity: identity,
                currentRemoteIdentity: other
            ))
        #expect(
            DocumentShownAnnouncementPolicy.shouldAnnounceNowShowing(
                previousRemoteIdentity: nil,
                currentRemoteIdentity: nil
            ))
        #expect(
            DocumentShownAnnouncementPolicy.shouldAnnounceNowShowing(
                previousRemoteIdentity: identity,
                currentRemoteIdentity: nil
            ))
        #expect(
            DocumentShownAnnouncementPolicy.shouldAnnounceNowShowing(
                previousRemoteIdentity: nil,
                currentRemoteIdentity: identity
            ))
    }
}

@Suite("Remote Refresh footer accessibility")
struct RemoteRefreshFooterAccessibilityTests {
    @Test("Refresh caption stays exposed to VoiceOver with the prior read-only origin label")
    func captionNotHiddenFromVoiceOver() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appending(
                path: "Sources/awesoMux/Views/DocumentPaneView.swift"),
            encoding: .utf8
        )
        // Pin the two halves of the fix: the caption under Refresh must carry
        // the historical AX label, and must not be accessibilityHidden.
        guard
            let refreshRange = source.range(
                of: "Caption under Refresh on a remote Markdown snapshot tab")
        else {
            Issue.record("missing Refresh caption localization comment")
            return
        }
        let afterCaption = source[refreshRange.upperBound...]
        let window = String(afterCaption.prefix(500))
        #expect(
            window.contains("Read-only remote Markdown snapshot from \\(origin)"),
            "Refresh caption must keep the prior VoiceOver label")
        #expect(
            !window.contains("accessibilityHidden(true)"),
            "Refresh caption must remain exposed to VoiceOver")
    }
}
