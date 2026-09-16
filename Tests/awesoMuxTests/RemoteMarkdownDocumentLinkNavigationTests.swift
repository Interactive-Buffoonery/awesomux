import Foundation
import Testing
@testable import AwesoMuxCore
@testable import awesoMux

@Suite("RemoteMarkdownDocumentLinkNavigation")
struct RemoteMarkdownDocumentLinkNavigationTests {
    private func remoteIdentity(
        path: String = "/repo/docs/README.md",
        target: String = "my-purple"
    ) -> ResourceIdentity {
        ResourceIdentity(
            location: .remote(RemoteTarget(parsing: target)!),
            path: ResourcePath(rawValue: path)
        )
    }

    @Test("open fetches through the shared pipeline and applies a remote tab")
    @MainActor
    func openFetchesAndAppliesRemoteTab() async throws {
        let store = SessionStore()
        let sessionID = store.addSession(workingDirectory: "/tmp")
        let source = remoteIdentity()
        let link = try #require(
            RemoteMarkdownReference.linkURL(
                forMarkdownDestination: "sibling.md",
                relativeTo: source
            )
        )

        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-md-link-\(UUID().uuidString).md")
        try "# sibling\n".write(to: cacheURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        var fetchedPath: String?
        let openedID = try #require(
            await RemoteMarkdownDocumentLinkNavigation.open(
                url: link,
                from: source,
                in: sessionID,
                associatedWith: nil,
                sessionStore: store,
                fetch: { reference in
                    fetchedPath = reference.remotePath
                    let identity = ResourceIdentity(
                        location: reference.identity.location,
                        path: ResourcePath(rawValue: reference.remotePath)
                    )
                    return .fresh(
                        RemoteMarkdownSnapshot(fileURL: cacheURL, identity: identity)
                    )
                },
                onRoutingFailure: {
                    Issue.record("routing failure should not fire for a valid link")
                }
            )
        )

        #expect(fetchedPath == "/repo/docs/sibling.md")
        let tab = try #require(
            store.session(id: sessionID)?.layout.firstDocumentGroup?.tab(id: openedID)
        )
        #expect(tab.remoteResourceIdentity?.path.rawValue == "/repo/docs/sibling.md")
        #expect(tab.isEditable == false)
        #expect(tab.fileURL.resolvingSymlinksInPath() == cacheURL.resolvingSymlinksInPath())
    }

    @Test("open fails closed and presents routing failure for escapes")
    @MainActor
    func openFailsClosedForEscapes() async {
        let store = SessionStore()
        let sessionID = store.addSession(workingDirectory: "/tmp")
        var failureCount = 0
        var loadingAnnouncements = 0
        let openedID = await RemoteMarkdownDocumentLinkNavigation.open(
            url: URL(fileURLWithPath: "/tmp/evil.md"),
            from: remoteIdentity(),
            in: sessionID,
            associatedWith: nil,
            sessionStore: store,
            fetch: { _ in
                Issue.record("fetch must not run for a rejected link")
                return nil
            },
            onRoutingFailure: { failureCount += 1 },
            onAnnounceLoading: { loadingAnnouncements += 1 }
        )
        #expect(openedID == nil)
        #expect(failureCount == 1)
        #expect(loadingAnnouncements == 0)
        #expect(store.session(id: sessionID)?.layout.firstDocumentGroup == nil)
    }

    @Test("open announces loading before fetch like OSC remote opens")
    @MainActor
    func openAnnouncesLoadingBeforeFetch() async throws {
        let store = SessionStore()
        let sessionID = store.addSession(workingDirectory: "/tmp")
        let source = remoteIdentity()
        let link = try #require(
            RemoteMarkdownReference.linkURL(
                forMarkdownDestination: "sibling.md",
                relativeTo: source
            )
        )
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-md-link-a11y-\(UUID().uuidString).md")
        try "# sibling\n".write(to: cacheURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        var events: [String] = []
        let openedID = try #require(
            await RemoteMarkdownDocumentLinkNavigation.open(
                url: link,
                from: source,
                in: sessionID,
                associatedWith: nil,
                sessionStore: store,
                fetch: { reference in
                    events.append("fetch:\(reference.remotePath)")
                    let identity = ResourceIdentity(
                        location: reference.identity.location,
                        path: ResourcePath(rawValue: reference.remotePath)
                    )
                    return .fresh(
                        RemoteMarkdownSnapshot(fileURL: cacheURL, identity: identity)
                    )
                },
                onRoutingFailure: {
                    Issue.record("routing failure should not fire for a valid link")
                },
                onAnnounceLoading: { events.append("loading") }
            )
        )

        #expect(events == ["loading", "fetch:/repo/docs/sibling.md"])
        #expect(openedID != nil)
        // Outcome announcement goes through apply(announceOutcome: true) →
        // TerminalAccessibilityAnnouncer; loading order vs fetch is the
        // interactive contract this test pins.
    }
}

@Suite("Remote markdown attributed document links")
struct RemoteMarkdownAttributedDocumentLinkTests {
    private func remoteIdentity(
        path: String = "/repo/docs/README.md"
    ) -> ResourceIdentity {
        ResourceIdentity(
            location: .remote(RemoteTarget(parsing: "my-purple")!),
            path: ResourcePath(rawValue: path)
        )
    }

    @Test("remote snapshots make relative Md→Md links clickable against the remote directory")
    func remoteSnapshotRelativeDocumentLinksAreClickable() throws {
        let doc = AttributedMarkdownBuilder.build(
            "[local](sibling.md) [escape](../secret.md) [web](https://example.com) [file](file:///tmp/evil.md)"
        )
        let attr = MarkdownAttributedStringBuilder.attributedString(
            for: doc,
            relativeLinkBaseURL: URL(fileURLWithPath: "/var/folders/cache"),
            remoteDocumentLinkIdentity: remoteIdentity(),
            allowsDocumentLinks: true
        )
        let localRange = try #require(attr.string.range(of: "local"))
        let escapeRange = try #require(attr.string.range(of: "escape"))
        let webRange = try #require(attr.string.range(of: "web"))
        let fileRange = try #require(attr.string.range(of: "file"))

        let localLink =
            attr.attribute(
                .link,
                at: NSRange(localRange, in: attr.string).location,
                effectiveRange: nil
            ) as? URL
        #expect(localLink == URL(fileURLWithPath: "/repo/docs/sibling.md"))
        #expect(
            attr.attribute(
                .link,
                at: NSRange(escapeRange, in: attr.string).location,
                effectiveRange: nil
            ) == nil
        )
        #expect(
            attr.attribute(
                .link,
                at: NSRange(webRange, in: attr.string).location,
                effectiveRange: nil
            ) != nil
        )
        #expect(
            attr.attribute(
                .link,
                at: NSRange(fileRange, in: attr.string).location,
                effectiveRange: nil
            ) == nil
        )
    }

    @Test("generated read-only documents still render document links as plain text")
    func generatedReadOnlyDocumentLinksStayPlainText() throws {
        let doc = AttributedMarkdownBuilder.build("[local](next.md) [web](https://example.com)")
        let attr = MarkdownAttributedStringBuilder.attributedString(
            for: doc,
            relativeLinkBaseURL: URL(fileURLWithPath: "/tmp"),
            allowsDocumentLinks: false
        )
        let localRange = try #require(attr.string.range(of: "local"))
        let webRange = try #require(attr.string.range(of: "web"))

        #expect(
            attr.attribute(
                .link,
                at: NSRange(localRange, in: attr.string).location,
                effectiveRange: nil
            ) == nil
        )
        #expect(
            attr.attribute(
                .link,
                at: NSRange(webRange, in: attr.string).location,
                effectiveRange: nil
            ) != nil
        )
    }
}
