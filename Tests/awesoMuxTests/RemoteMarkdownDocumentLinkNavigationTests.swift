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

    /// Lets a test hold one open inside `fetch` while it starts a second click.
    private final class FetchGate: @unchecked Sendable {
        private let lock = NSLock()
        private var started: CheckedContinuation<Void, Never>?
        private var release: CheckedContinuation<Void, Never>?
        private var hasStarted = false
        private var isReleased = false

        func waitThenReturn() async {
            markStarted()
            await waitForRelease()
        }

        func waitUntilStarted() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if hasStarted {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                started = continuation
                lock.unlock()
            }
        }

        func releaseGate() {
            lock.lock()
            isReleased = true
            let waiter = release
            release = nil
            lock.unlock()
            waiter?.resume()
        }

        private func markStarted() {
            lock.lock()
            hasStarted = true
            let waiter = started
            started = nil
            lock.unlock()
            waiter?.resume()
        }

        private func waitForRelease() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if isReleased {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                release = continuation
                lock.unlock()
            }
        }
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
        // Outcome announcement goes through apply(announceOutcome: isFirstWaiter) →
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

    @Test("a nil fetch after session close does not present stale failure UI")
    @MainActor
    func nilFetchAfterSessionCloseStaysSilent() async throws {
        let store = SessionStore()
        let sessionID = store.addSession(workingDirectory: "/tmp")
        let source = remoteIdentity()
        let link = try #require(
            RemoteMarkdownReference.linkURL(
                forMarkdownDestination: "sibling.md",
                relativeTo: source
            )
        )
        var fetchFailures = 0

        let openedID = await RemoteMarkdownDocumentLinkNavigation.open(
            url: link,
            from: source,
            in: sessionID,
            associatedWith: nil,
            sessionStore: store,
            fetch: { _ in
                store.closeSession(id: sessionID)
                return nil
            },
            onFetchFailure: { fetchFailures += 1 },
            onAnnounceLoading: {}
        )

        #expect(openedID == nil)
        #expect(fetchFailures == 0)
    }

    @Test("a fragment link scrolls an already-open tab before announcing its landing")
    @MainActor
    func alreadyOpenFragmentTargetScrollsAndAnnouncesAtTop() async throws {
        let store = SessionStore()
        let sessionID = store.addSession(workingDirectory: "/tmp")
        let source = remoteIdentity()
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
    }

    @Test("a coalesced fragment link scrolls without duplicating speech")
    @MainActor
    func coalescedFragmentLinkStillScrolls() async throws {
        let store = SessionStore()
        let sessionID = store.addSession(workingDirectory: "/tmp")
        let source = remoteIdentity()
        let progress = RemoteMarkdownFetchProgressCoordinator()
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-md-link-coalesced-\(UUID().uuidString).md")
        try "# sibling\n".write(to: cacheURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        let link = try #require(
            RemoteMarkdownReference.linkURL(
                forMarkdownDestination: "sibling.md#install",
                relativeTo: source
            )
        )
        let reference = try #require(
            RemoteMarkdownDocumentLinkNavigation.reference(forOpenedLinkURL: link, from: source)
        )
        _ = store.openDocumentPane(
            fileURL: cacheURL,
            in: sessionID,
            remoteResourceIdentity: reference.identity
        )
        let cohort = RemoteMarkdownFetchCoordinator.Cohort()
        #expect(cohort.register(.refresh, sessionID: sessionID))
        #expect(!cohort.register(.document, sessionID: sessionID))

        var scrolledTabID: DocumentPane.ID?
        var fragmentAnnouncements = 0
        let openedID = try #require(
            await RemoteMarkdownDocumentLinkNavigation.open(
                url: link,
                from: source,
                in: sessionID,
                associatedWith: nil,
                sessionStore: store,
                startAttempt: { reference in
                    .init(
                        cohort: cohort,
                        announcementSessionID: sessionID,
                        ownsAnnouncements: false,
                        task: Task {
                            .fresh(
                                RemoteMarkdownSnapshot(
                                    fileURL: cacheURL,
                                    identity: reference.identity
                                )
                            )
                        },
                        isNew: false,
                        onCoalesced: nil,
                        onRegistered: nil,
                        onFinished: nil
                    )
                },
                onRoutingFailure: { Issue.record("routing failure should not fire") },
                onAnnounceLoading: { Issue.record("coalesced link should not announce loading") },
                onAnnounceFragmentOpened: { fragmentAnnouncements += 1 },
                onScrollFragmentTargetToTop: { tabID in
                    scrolledTabID = tabID
                    return true
                },
                progress: progress
            )
        )

        #expect(scrolledTabID == openedID)
        #expect(fragmentAnnouncements == 0)
    }

    @Test("a fragment link announces at-top when the already-open tab closes during fetch")
    @MainActor
    func fragmentLinkAnnouncesAtTopWhenTabClosesDuringFetch() async throws {
        let store = SessionStore()
        let sessionID = store.addSession(workingDirectory: "/tmp")
        let source = remoteIdentity()
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-md-link-close-during-fetch-\(UUID().uuidString).md")
        try "# sibling\n".write(to: cacheURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        var fragmentAnnouncements = 0
        func open(
            destination: String,
            closeExistingDuringFetch: Bool
        ) async throws -> DocumentPane.ID? {
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
                    if closeExistingDuringFetch,
                        let existing = store.session(id: sessionID)?
                            .layout.firstDocumentGroup?
                            .tab(forRemoteResource: reference.identity)
                    {
                        store.closeDocumentPane(documentID: existing.id, in: sessionID)
                    }
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

        let firstID = try #require(
            await open(destination: "sibling.md#install", closeExistingDuringFetch: false)
        )
        #expect(fragmentAnnouncements == 1)
        let secondID = try #require(
            await open(destination: "sibling.md#install", closeExistingDuringFetch: true)
        )
        #expect(secondID != firstID)
        #expect(fragmentAnnouncements == 2)
    }

    @Test("a fragment link resets a tab another task opens during fetch")
    @MainActor
    func fragmentLinkStaysSilentWhenTabOpensDuringFetch() async throws {
        let store = SessionStore()
        let sessionID = store.addSession(workingDirectory: "/tmp")
        let source = remoteIdentity()
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-md-link-open-during-fetch-\(UUID().uuidString).md")
        try "# sibling\n".write(to: cacheURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        var fragmentAnnouncements = 0
        var resetTabID: DocumentPane.ID?
        let link = try #require(
            RemoteMarkdownReference.linkURL(
                forMarkdownDestination: "sibling.md#install",
                relativeTo: source
            )
        )
        let openedID = try #require(
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
                    _ = store.openDocumentPane(
                        fileURL: cacheURL,
                        in: sessionID,
                        remoteResourceIdentity: identity
                    )
                    return .fresh(
                        RemoteMarkdownSnapshot(fileURL: cacheURL, identity: identity)
                    )
                },
                onRoutingFailure: { Issue.record("routing failure should not fire") },
                onAnnounceLoading: {},
                onAnnounceFragmentOpened: { fragmentAnnouncements += 1 },
                onScrollFragmentTargetToTop: { tabID in
                    resetTabID = tabID
                    return true
                }
            )
        )
        #expect(openedID != nil)
        #expect(resetTabID == openedID)
        #expect(fragmentAnnouncements == 1)
    }

    @Test("a second open for the same in-flight link is dropped")
    @MainActor
    func secondOpenForSameInFlightLinkIsDropped() async throws {
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
            .appendingPathComponent("remote-md-link-latch-\(UUID().uuidString).md")
        try "# sibling\n".write(to: cacheURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        // A private coordinator so the process-wide latch other tests use does
        // not interact with this one.
        let coordinator = RemoteMarkdownDocumentLinkCoordinator()
        let gate = FetchGate()
        var loadingAnnouncements = 0

        let first = Task { @MainActor in
            await RemoteMarkdownDocumentLinkNavigation.open(
                url: link,
                from: source,
                in: sessionID,
                associatedWith: nil,
                sessionStore: store,
                coordinator: coordinator,
                fetch: { reference in
                    await gate.waitThenReturn()
                    return .fresh(
                        RemoteMarkdownSnapshot(
                            fileURL: cacheURL,
                            identity: reference.identity
                        )
                    )
                },
                onRoutingFailure: { Issue.record("routing failure should not fire") },
                onAnnounceLoading: { loadingAnnouncements += 1 }
            )
        }

        await gate.waitUntilStarted()
        let second = await RemoteMarkdownDocumentLinkNavigation.open(
            url: link,
            from: source,
            in: sessionID,
            associatedWith: nil,
            sessionStore: store,
            coordinator: coordinator,
            fetch: { _ in
                Issue.record("the dropped second open must not fetch")
                return nil
            },
            onAnnounceLoading: { loadingAnnouncements += 1 }
        )
        #expect(second == nil)

        gate.releaseGate()
        let firstID = await first.value
        #expect(firstID != nil)
        #expect(loadingAnnouncements == 1)
    }

    @Test("concurrent opens in different sessions for the same link are not dropped")
    @MainActor
    func concurrentOpensInDifferentSessionsAreNotDropped() async throws {
        let store = SessionStore()
        let firstSessionID = store.addSession(workingDirectory: "/tmp")
        let secondSessionID = store.addSession(workingDirectory: "/tmp")
        let source = remoteIdentity()
        let link = try #require(
            RemoteMarkdownReference.linkURL(
                forMarkdownDestination: "sibling.md",
                relativeTo: source
            )
        )
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-md-link-cross-session-\(UUID().uuidString).md")
        try "# sibling\n".write(to: cacheURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        let coordinator = RemoteMarkdownDocumentLinkCoordinator()
        let gate = FetchGate()
        var fetchCount = 0

        let first = Task { @MainActor in
            await RemoteMarkdownDocumentLinkNavigation.open(
                url: link,
                from: source,
                in: firstSessionID,
                associatedWith: nil,
                sessionStore: store,
                coordinator: coordinator,
                fetch: { reference in
                    await gate.waitThenReturn()
                    return .fresh(
                        RemoteMarkdownSnapshot(
                            fileURL: cacheURL,
                            identity: reference.identity
                        )
                    )
                },
                onRoutingFailure: { Issue.record("routing failure should not fire") },
                onAnnounceLoading: {}
            )
        }

        await gate.waitUntilStarted()
        fetchCount += 1
        let second = await RemoteMarkdownDocumentLinkNavigation.open(
            url: link,
            from: source,
            in: secondSessionID,
            associatedWith: nil,
            sessionStore: store,
            coordinator: coordinator,
            fetch: { reference in
                fetchCount += 1
                return .fresh(
                    RemoteMarkdownSnapshot(
                        fileURL: cacheURL,
                        identity: reference.identity
                    )
                )
            },
            onRoutingFailure: { Issue.record("routing failure should not fire") },
            onAnnounceLoading: {}
        )
        #expect(second != nil)

        gate.releaseGate()
        let firstID = await first.value
        #expect(firstID != nil)
        #expect(fetchCount == 2)
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
