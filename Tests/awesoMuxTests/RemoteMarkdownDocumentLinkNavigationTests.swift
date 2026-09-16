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

    @Test("link URLs preserve fragments for the click path")
    func linkURLPreservesFragment() throws {
        let source = remoteIdentity()
        let absolute = try #require(
            RemoteMarkdownReference.linkURL(
                forMarkdownDestination: "sibling.md#install",
                relativeTo: source
            )
        )
        #expect(absolute.fragment == "install")
        #expect(absolute.path == "/repo/docs/sibling.md")

        let tildeSource = remoteIdentity(path: "~/repo/docs/README.md")
        let tilde = try #require(
            RemoteMarkdownReference.linkURL(
                forMarkdownDestination: "guide.md#install",
                relativeTo: tildeSource
            )
        )
        #expect(tilde.fragment == "install")
        // The fragment rides along for the announcement only: identity stays
        // fragment-free, and the click gate still resolves the same reference.
        let reopened = try #require(
            RemoteMarkdownReference.make(openedLinkURL: tilde, relativeTo: tildeSource)
        )
        #expect(reopened.remotePath == "~/repo/docs/guide.md")
    }

    @Test("open announces the at-top landing only for fragment links")
    @MainActor
    func openAnnouncesAtTopLandingForFragmentLinks() async throws {
        let store = SessionStore()
        let sessionID = store.addSession(workingDirectory: "/tmp")
        let source = remoteIdentity()
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-md-link-fragment-\(UUID().uuidString).md")
        try "# sibling\n".write(to: cacheURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        var fragmentAnnouncements = 0
        func open(destination: String) async throws -> DocumentPane.ID? {
            let link = try #require(
                RemoteMarkdownReference.linkURL(
                    forMarkdownDestination: destination,
                    relativeTo: source
                )
            )
            return await RemoteMarkdownDocumentLinkNavigation.open(
                url: link,
                from: source,
                in: sessionID,
                associatedWith: nil,
                sessionStore: store,
                fetch: { reference in
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
                onAnnounceLoading: {},
                onAnnounceFragmentOpened: { fragmentAnnouncements += 1 }
            )
        }

        let fragmented = try #require(await open(destination: "sibling.md#install"))
        #expect(fragmentAnnouncements == 1)
        // The fragment opens the same document a plain link would.
        let tab = try #require(
            store.session(id: sessionID)?.layout.firstDocumentGroup?.tab(id: fragmented)
        )
        #expect(tab.remoteResourceIdentity?.path.rawValue == "/repo/docs/sibling.md")

        _ = try #require(await open(destination: "sibling.md"))
        #expect(fragmentAnnouncements == 1)
    }

    @Test("open stays silent for fragment links when apply returns nil")
    @MainActor
    func openStaysSilentForFragmentWhenApplyReturnsNil() async throws {
        let store = SessionStore()
        let sessionID = store.addSession(workingDirectory: "/tmp")
        let source = remoteIdentity()
        let link = try #require(
            RemoteMarkdownReference.linkURL(
                forMarkdownDestination: "sibling.md#install",
                relativeTo: source
            )
        )
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-md-link-fragment-nil-\(UUID().uuidString).md")
        try "# sibling\n".write(to: cacheURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        var fragmentAnnouncements = 0
        let openedID = await RemoteMarkdownDocumentLinkNavigation.open(
            url: link,
            from: source,
            in: sessionID,
            associatedWith: nil,
            sessionStore: store,
            fetch: { reference in
                store.closeSession(id: sessionID)
                let identity = ResourceIdentity(
                    location: reference.identity.location,
                    path: ResourcePath(rawValue: reference.remotePath)
                )
                return .fresh(
                    RemoteMarkdownSnapshot(fileURL: cacheURL, identity: identity)
                )
            },
            onAnnounceLoading: {},
            onAnnounceFragmentOpened: { fragmentAnnouncements += 1 }
        )
        #expect(openedID == nil)
        #expect(fragmentAnnouncements == 0)
    }

    @Test("open stays silent for fragment links when fetch returns stale cache")
    @MainActor
    func openStaysSilentForFragmentWhenFetchReturnsStaleCache() async throws {
        let store = SessionStore()
        let sessionID = store.addSession(workingDirectory: "/tmp")
        let source = remoteIdentity()
        let link = try #require(
            RemoteMarkdownReference.linkURL(
                forMarkdownDestination: "sibling.md#install",
                relativeTo: source
            )
        )
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-md-link-fragment-cached-\(UUID().uuidString).md")
        try "# sibling\n".write(to: cacheURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        var fragmentAnnouncements = 0
        _ = try #require(
            await RemoteMarkdownDocumentLinkNavigation.open(
                url: link,
                from: source,
                in: sessionID,
                associatedWith: nil,
                sessionStore: store,
                fetch: { reference in
                    let identity = ResourceIdentity(
                        location: reference.identity.location,
                        path: ResourcePath(rawValue: reference.remotePath)
                    )
                    return .cached(
                        RemoteMarkdownSnapshot(fileURL: cacheURL, identity: identity),
                        staleReason: .connection
                    )
                },
                onAnnounceLoading: {},
                onAnnounceFragmentOpened: { fragmentAnnouncements += 1 }
            )
        )
        #expect(fragmentAnnouncements == 0)
    }

    @Test("open stays silent for fragment links when fetch returns a failure document")
    @MainActor
    func openStaysSilentForFragmentWhenFetchReturnsFailureDocument() async throws {
        let store = SessionStore()
        let sessionID = store.addSession(workingDirectory: "/tmp")
        let source = remoteIdentity()
        let link = try #require(
            RemoteMarkdownReference.linkURL(
                forMarkdownDestination: "sibling.md#install",
                relativeTo: source
            )
        )
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-md-link-fragment-failure-\(UUID().uuidString).md")
        try "# Couldn't fetch remote Markdown\n".write(to: cacheURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        var fragmentAnnouncements = 0
        _ = try #require(
            await RemoteMarkdownDocumentLinkNavigation.open(
                url: link,
                from: source,
                in: sessionID,
                associatedWith: nil,
                sessionStore: store,
                fetch: { reference in
                    let identity = ResourceIdentity(
                        location: reference.identity.location,
                        path: ResourcePath(rawValue: reference.remotePath)
                    )
                    return .failureDocument(
                        RemoteMarkdownSnapshot(fileURL: cacheURL, identity: identity),
                        reason: .connection
                    )
                },
                onAnnounceLoading: {},
                onAnnounceFragmentOpened: { fragmentAnnouncements += 1 }
            )
        )
        #expect(fragmentAnnouncements == 0)
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

    /// A nil fetch is a local write failure, not a rejected destination, so it
    /// must not present the boundary-violation copy.
    @Test("open routes a nil fetch to the fetch-failure hook, not the path gate")
    @MainActor
    func openRoutesNilFetchToFetchFailure() async throws {
        let store = SessionStore()
        let sessionID = store.addSession(workingDirectory: "/tmp")
        let source = remoteIdentity()
        let link = try #require(
            RemoteMarkdownReference.linkURL(
                forMarkdownDestination: "sibling.md",
                relativeTo: source
            )
        )
        var routingFailures = 0
        var fetchFailures = 0
        let openedID = await RemoteMarkdownDocumentLinkNavigation.open(
            url: link,
            from: source,
            in: sessionID,
            associatedWith: nil,
            sessionStore: store,
            fetch: { _ in nil },
            onRoutingFailure: { routingFailures += 1 },
            onFetchFailure: { fetchFailures += 1 },
            onAnnounceLoading: {}
        )
        #expect(openedID == nil)
        #expect(routingFailures == 0)
        #expect(fetchFailures == 1)
    }

    /// An already-open target does not move: a self-link stays put and a
    /// background tab reopens at its saved position. Announcing "opened at the
    /// top" for either would be false, so the cue fires only for a new tab.
    @Test("a fragment link to an already-open tab does not announce an at-top landing")
    @MainActor
    func alreadyOpenFragmentTargetDoesNotAnnounceAtTop() async throws {
        let store = SessionStore()
        let sessionID = store.addSession(workingDirectory: "/tmp")
        let source = remoteIdentity()
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-md-link-reopen-\(UUID().uuidString).md")
        try "# sibling\n".write(to: cacheURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        var fragmentAnnouncements = 0
        func open(destination: String) async throws -> DocumentPane.ID? {
            let link = try #require(
                RemoteMarkdownReference.linkURL(
                    forMarkdownDestination: destination,
                    relativeTo: source
                )
            )
            return await RemoteMarkdownDocumentLinkNavigation.open(
                url: link,
                from: source,
                in: sessionID,
                associatedWith: nil,
                sessionStore: store,
                fetch: { reference in
                    let identity = ResourceIdentity(
                        location: reference.identity.location,
                        path: ResourcePath(rawValue: reference.remotePath)
                    )
                    return .fresh(
                        RemoteMarkdownSnapshot(fileURL: cacheURL, identity: identity)
                    )
                },
                onRoutingFailure: { Issue.record("routing failure should not fire") },
                onAnnounceLoading: {},
                onAnnounceFragmentOpened: { fragmentAnnouncements += 1 }
            )
        }

        // First open mounts a new tab, so the at-top cue is true.
        _ = try #require(await open(destination: "sibling.md#install"))
        #expect(fragmentAnnouncements == 1)
        // Second open hits the already-open tab and must stay silent.
        _ = try #require(await open(destination: "sibling.md#install"))
        #expect(fragmentAnnouncements == 1)
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

@Suite("Remote Markdown fragment announcement catalog coverage")
struct RemoteMarkdownFragmentAnnouncementCatalogTests {
    @Test func fragmentAnnouncementLiteralIsCatalogKey() throws {
        let keys = try AwesoMuxStringCatalog.keys()
        #expect(
            keys.contains("Opened at the top of the document. Section jumps are not supported yet."),
            "Localizable.xcstrings has no key for the fragment at-top announcement")
    }
}
