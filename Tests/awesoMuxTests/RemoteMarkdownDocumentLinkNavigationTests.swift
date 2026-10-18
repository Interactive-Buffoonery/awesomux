import Foundation
import Testing
@testable import AwesoMuxCore
@testable import awesoMux

// Serialized: several tests open the same link, and the default open latch is
// process-wide, so overlap between tests would drop an open.
@Suite("RemoteMarkdownDocumentLinkNavigation", .serialized)
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

    @MainActor
    private func installSource(_ identity: ResourceIdentity, in sessionID: TerminalSession.ID, store: SessionStore) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("remote-md-source-\(UUID().uuidString).md")
        try "# source\n".write(to: url, atomically: true, encoding: .utf8)
        _ = try #require(
            store.openDocumentPane(fileURL: url, in: sessionID, remoteResourceIdentity: identity, associationPolicy: .preserveNil))
        return url
    }

    /// Lets a test hold one open inside `fetch` while it starts a second click.
    @Test("open fetches through the shared pipeline and applies a remote tab")
    @MainActor
    func openFetchesAndAppliesRemoteTab() async throws {
        let store = SessionStore()
        let sessionID = store.addSession(workingDirectory: "/tmp")
        let source = remoteIdentity()
        let sourceURL = try installSource(source, in: sessionID, store: store)
        defer { try? FileManager.default.removeItem(at: sourceURL) }
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

    @MainActor
    @Test(
        "fragment outcomes announce only a live fresh landing",
        arguments: [
            "openAnnouncesAtTopLandingForFragmentLinks", "openStaysSilentForFragmentWhenApplyReturnsNil",
            "openStaysSilentForFragmentWhenFetchReturnsStaleCache", "openStaysSilentForFragmentWhenFetchReturnsFailureDocument",
            "alreadyOpenFragmentTargetScrollsAndAnnouncesAtTop",
        ])
    func fragmentOutcomes(scenario: String) async throws {
        switch scenario {
        case "openAnnouncesAtTopLandingForFragmentLinks":
            let store = SessionStore()
            let sessionID = store.addSession(workingDirectory: "/tmp")
            let source = remoteIdentity()
            let sourceURL = try installSource(source, in: sessionID, store: store)
            defer { try? FileManager.default.removeItem(at: sourceURL) }
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
        case "openStaysSilentForFragmentWhenApplyReturnsNil":
            let store = SessionStore()
            let sessionID = store.addSession(workingDirectory: "/tmp")
            let source = remoteIdentity()
            let sourceURL = try installSource(source, in: sessionID, store: store)
            defer { try? FileManager.default.removeItem(at: sourceURL) }
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
        case "openStaysSilentForFragmentWhenFetchReturnsStaleCache":
            let store = SessionStore()
            let sessionID = store.addSession(workingDirectory: "/tmp")
            let source = remoteIdentity()
            let sourceURL = try installSource(source, in: sessionID, store: store)
            defer { try? FileManager.default.removeItem(at: sourceURL) }
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
        case "openStaysSilentForFragmentWhenFetchReturnsFailureDocument":
            let store = SessionStore()
            let sessionID = store.addSession(workingDirectory: "/tmp")
            let source = remoteIdentity()
            let sourceURL = try installSource(source, in: sessionID, store: store)
            defer { try? FileManager.default.removeItem(at: sourceURL) }
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
        case "alreadyOpenFragmentTargetScrollsAndAnnouncesAtTop":
            let store = SessionStore()
            let sessionID = store.addSession(workingDirectory: "/tmp")
            let source = remoteIdentity()
            let sourceURL = try installSource(source, in: sessionID, store: store)
            defer { try? FileManager.default.removeItem(at: sourceURL) }
            let cacheURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("remote-md-link-reopen-\(UUID().uuidString).md")
            try "# sibling\n".write(to: cacheURL, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: cacheURL) }

            var fragmentAnnouncements = 0
            var scrolledTabIDs: [DocumentPane.ID] = []
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
                    onAnnounceFragmentOpened: { fragmentAnnouncements += 1 },
                    onScrollFragmentTargetToTop: { tabID in
                        scrolledTabIDs.append(tabID)
                        return true
                    }
                )
            }

            // First open mounts a new tab, so the at-top cue is true.
            _ = try #require(await open(destination: "sibling.md#install"))
            #expect(fragmentAnnouncements == 1)
            // Second open hits the already-open tab, resets it, then truthfully
            // announces the same visible landing.
            let reopened = try #require(await open(destination: "sibling.md#install"))
            #expect(scrolledTabIDs == [reopened])
            #expect(fragmentAnnouncements == 2)
        default: Issue.record("Unknown scenario: \(scenario)")
        }
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

    @Test(
        "document links respect remote containment and generated-document policy",
        arguments: ["remoteSnapshotRelativeDocumentLinksAreClickable", "generatedReadOnlyDocumentLinksStayPlainText"])
    func clickableLinks(scenario: String) async throws {
        switch scenario {
        case "remoteSnapshotRelativeDocumentLinksAreClickable":
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

            let localLink = try #require(
                attr.attribute(
                    .link,
                    at: NSRange(localRange, in: attr.string).location,
                    effectiveRange: nil
                ) as? URL
            )
            // Absolute remote destinations use the scheme, not a local `file://`
            // URL, so nothing downstream can mistake them for files on this Mac.
            #expect(localLink.scheme == RemoteMarkdownReference.remoteMarkdownLinkScheme)
            #expect(!localLink.isFileURL)
            #expect(
                RemoteMarkdownReference.make(openedLinkURL: localLink, relativeTo: remoteIdentity())?
                    .remotePath == "/repo/docs/sibling.md"
            )
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
        case "generatedReadOnlyDocumentLinksStayPlainText":
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
        default: Issue.record("Unknown scenario: \(scenario)")
        }
    }

}
