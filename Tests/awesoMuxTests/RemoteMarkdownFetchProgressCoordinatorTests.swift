import AwesoMuxCore
import AwesoMuxTestSupport
import Foundation
import Testing

@testable import awesoMux

@MainActor
@Suite("Remote Markdown fetch progress coordinator")
struct RemoteMarkdownFetchProgressCoordinatorTests {
    private func identity(path: String = "/repo/doc.md") -> ResourceIdentity {
        ResourceIdentity(
            location: .remote(RemoteTarget(parsing: "devbox")!),
            path: ResourcePath(rawValue: path)
        )
    }

    @Test("first waiter returns true; coalesced waiter returns false")
    func firstWaiterIsDistinguished() {
        let progress = RemoteMarkdownFetchProgressCoordinator()
        let sessionID = UUID()
        let identity = identity()
        #expect(
            progress.begin(
                sessionID: sessionID,
                identity: identity,
                origin: .document
            )
        )
        #expect(
            !progress.begin(
                sessionID: sessionID,
                identity: identity,
                origin: .document
            )
        )
        #expect(progress.isInFlight(sessionID: sessionID, identity: identity))
        progress.finish(sessionID: sessionID, identity: identity, origin: .document)
        #expect(progress.isDocumentBusy(sessionID: sessionID))
        progress.finish(sessionID: sessionID, identity: identity, origin: .document)
        #expect(!progress.isInFlight(sessionID: sessionID, identity: identity))
        #expect(!progress.isDocumentBusy(sessionID: sessionID))
    }

    @Test("surface and document origins do not share chrome")
    func surfaceAndDocumentOriginsAreIndependent() {
        let progress = RemoteMarkdownFetchProgressCoordinator()
        let sessionID = UUID()
        let paneID = UUID()
        let identity = identity()
        _ = progress.begin(
            sessionID: sessionID,
            identity: identity,
            origin: .surface(paneID: paneID)
        )
        #expect(progress.isSurfaceBusy(sessionID: sessionID, paneID: paneID))
        #expect(!progress.isDocumentBusy(sessionID: sessionID))
        _ = progress.begin(
            sessionID: sessionID,
            identity: identity(path: "/repo/other.md"),
            origin: .document
        )
        #expect(progress.isDocumentBusy(sessionID: sessionID))
        progress.finish(
            sessionID: sessionID,
            identity: identity,
            origin: .surface(paneID: paneID)
        )
        #expect(!progress.isSurfaceBusy(sessionID: sessionID, paneID: paneID))
        #expect(progress.isDocumentBusy(sessionID: sessionID))
    }

    @Test("different sessions and identities do not block each other")
    func keysAreIndependent() {
        let progress = RemoteMarkdownFetchProgressCoordinator()
        let firstSession = UUID()
        let secondSession = UUID()
        let first = identity()
        let second = identity(path: "/repo/other.md")
        #expect(progress.begin(sessionID: firstSession, identity: first, origin: .document))
        #expect(progress.begin(sessionID: firstSession, identity: second, origin: .document))
        #expect(progress.begin(sessionID: secondSession, identity: first, origin: .document))
        progress.finish(sessionID: firstSession, identity: first, origin: .document)
        #expect(!progress.isInFlight(sessionID: firstSession, identity: first))
        #expect(progress.isInFlight(sessionID: firstSession, identity: second))
        #expect(progress.isInFlight(sessionID: secondSession, identity: first))
    }

    @Test("registered surface reshows after a visual clear while still in flight")
    func registeredSurfaceReshowsAfterClear() {
        let progress = RemoteMarkdownFetchProgressCoordinator()
        let sessionID = UUID()
        let paneID = UUID()
        let presenter = FakeSurfacePresenter()
        progress.registerSurface(presenter, sessionID: sessionID, paneID: paneID)
        #expect(!presenter.isBusy)

        _ = progress.begin(
            sessionID: sessionID,
            identity: identity(),
            origin: .surface(paneID: paneID)
        )
        #expect(presenter.isBusy)

        presenter.isBusy = false
        progress.registerSurface(presenter, sessionID: sessionID, paneID: paneID)
        #expect(presenter.isBusy)

        progress.finish(
            sessionID: sessionID,
            identity: identity(),
            origin: .surface(paneID: paneID)
        )
        #expect(!presenter.isBusy)
    }

    @Test("re-registering a surface for a new pane syncs the new identity")
    func reregisterSyncsNewPane() {
        let progress = RemoteMarkdownFetchProgressCoordinator()
        let sessionID = UUID()
        let firstPane = UUID()
        let secondPane = UUID()
        let presenter = FakeSurfacePresenter()
        _ = progress.begin(
            sessionID: sessionID,
            identity: identity(),
            origin: .surface(paneID: firstPane)
        )
        progress.registerSurface(presenter, sessionID: sessionID, paneID: firstPane)
        #expect(presenter.isBusy)

        progress.registerSurface(presenter, sessionID: sessionID, paneID: secondPane)
        #expect(!presenter.isBusy)

        _ = progress.begin(
            sessionID: sessionID,
            identity: identity(path: "/repo/other.md"),
            origin: .surface(paneID: secondPane)
        )
        #expect(presenter.isBusy)
    }

    private final class FakeSurfacePresenter: RemoteMarkdownFetchProgressSurfacePresenting {
        var isBusy = false

        func syncRemoteMarkdownFetchProgress(isBusy: Bool) {
            self.isBusy = isBusy
        }
    }
}

@MainActor
@Suite("Remote Markdown fetch progress wiring")
struct RemoteMarkdownFetchProgressWiringTests {
    @Test("Md→Md announces loading only for the first waiter")
    func documentLinkFirstWaiterOnlyAnnouncesLoading() async throws {
        let store = SessionStore()
        let sessionID = store.addSession(workingDirectory: "/tmp")
        let source = ResourceIdentity(
            location: .remote(RemoteTarget(parsing: "my-purple")!),
            path: ResourcePath(rawValue: "/repo/docs/README.md")
        )
        let link = try #require(
            RemoteMarkdownReference.linkURL(
                forMarkdownDestination: "sibling.md",
                relativeTo: source
            )
        )
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-md-progress-\(UUID().uuidString).md")
        try "# sibling\n".write(to: cacheURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        let progress = RemoteMarkdownFetchProgressCoordinator()
        let hold = AsyncGate()
        var loadingCount = 0

        func outcome(for reference: RemoteMarkdownReference) -> RemoteMarkdownFetchOutcome {
            .fresh(
                RemoteMarkdownSnapshot(
                    fileURL: cacheURL,
                    identity: ResourceIdentity(
                        location: reference.identity.location,
                        path: ResourcePath(rawValue: reference.remotePath)
                    )
                )
            )
        }

        let first = Task { @MainActor in
            await RemoteMarkdownDocumentLinkNavigation.open(
                url: link,
                from: source,
                in: sessionID,
                associatedWith: nil,
                sessionStore: store,
                fetch: { reference in
                    await hold.wait()
                    return outcome(for: reference)
                },
                onAnnounceLoading: { loadingCount += 1 },
                progress: progress
            )
        }

        #expect(await waitUntil { progress.isDocumentBusy(sessionID: sessionID) })
        #expect(loadingCount == 1)

        let secondID = await RemoteMarkdownDocumentLinkNavigation.open(
            url: link,
            from: source,
            in: sessionID,
            associatedWith: nil,
            sessionStore: store,
            fetch: { reference in
                hold.open()
                return outcome(for: reference)
            },
            onAnnounceLoading: { loadingCount += 1 },
            progress: progress
        )

        _ = await first.value
        #expect(secondID != nil)
        #expect(loadingCount == 1)
        #expect(!progress.isDocumentBusy(sessionID: sessionID))
        #expect(store.session(id: sessionID)?.layout.firstDocumentGroup?.tabs.count == 1)
    }

    @Test("typed-path origin is document from a snapshot tab and surface from SSH")
    func typedPathOriginFollowsContext() {
        let target = RemoteTarget(parsing: "my-purple")!
        let sshPane = TerminalPane(
            title: "ssh",
            workingDirectory: "~",
            executionPlan: .ssh(SSHExecution(target: target))
        )
        let sshSession = TerminalSession(
            title: "ssh",
            workingDirectory: "~",
            layout: .pane(sshPane),
            activePaneID: sshPane.id
        )
        #expect(
            RemoteMarkdownTypedPathOpen.fetchProgressOrigin(for: sshSession)
                == .surface(paneID: sshPane.id)
        )

        let identity = ResourceIdentity(
            location: .remote(target),
            path: ResourcePath(rawValue: "/repo/README.md")
        )
        var tab = DocumentPane(
            fileURL: URL(fileURLWithPath: "/tmp/cache.md"),
            title: "README.md",
            remoteResourceIdentity: identity
        )
        tab.associatedTerminalPaneID = sshPane.id
        let group = DocumentGroup(tabs: [tab], selectedTabID: tab.id)
        let snapshotSession = TerminalSession(
            title: "docs",
            workingDirectory: "~",
            layout: .split(
                TerminalSplit(
                    orientation: .horizontal,
                    first: .pane(sshPane),
                    second: .documentGroup(group)
                )
            ),
            activePaneID: sshPane.id
        )
        #expect(RemoteMarkdownTypedPathOpen.fetchProgressOrigin(for: snapshotSession) == .document)
    }

    @Test("announceLoadingIfValid stays silent for a coalesced waiter")
    func typedPathLoadingSkipsCoalescedWaiter() {
        let target = RemoteTarget(parsing: "my-purple")!
        let progress = RemoteMarkdownFetchProgressCoordinator()
        let sessionID = UUID()
        let identity = ResourceIdentity(
            location: .remote(target),
            path: ResourcePath(rawValue: "/repo/NOTES.md")
        )
        _ = progress.begin(sessionID: sessionID, identity: identity, origin: .document)

        var announcements = 0
        #expect(
            RemoteMarkdownTypedPathOpen.announceLoadingIfValid(
                typedPath: "/repo/NOTES.md",
                target: target,
                sessionID: sessionID,
                progress: progress,
                onAnnounceLoading: { announcements += 1 }
            )
        )
        #expect(announcements == 0)
    }
}

@Suite("Remote Markdown fetch progress source contracts")
struct RemoteMarkdownFetchProgressSourceContractTests {
    @Test("document overlay sits outside remount identity")
    func documentOverlayDoesNotChangeRemountIdentity() throws {
        let source = try SourceContract.source(at: "Sources/awesoMux/Views/DocumentGroupView.swift")
        #expect(source.contains(".id(DocumentPaneContentIdentity.remountID(for: document))"))
        #expect(source.contains("RemoteMarkdownFetchProgressOverlay()"))
        let remountIndex = try #require(source.range(of: ".id(DocumentPaneContentIdentity.remountID(for: document))"))
        let overlayIndex = try #require(source.range(of: "RemoteMarkdownFetchProgressOverlay()"))
        #expect(remountIndex.lowerBound < overlayIndex.lowerBound)
    }

    @Test("footer Refresh shows a spinner while the coordinator is busy")
    func footerRefreshShowsSpinner() throws {
        let source = try SourceContract.source(at: "Sources/awesoMux/Views/DocumentPaneView.swift")
        let controls = try SourceContract.declarationBody(
            after: "private func remoteSnapshotControls(origin: String) -> some View {",
            in: source,
            path: "Sources/awesoMux/Views/DocumentPaneView.swift"
        )
        #expect(controls.contains("if isRemoteRefreshing"))
        #expect(controls.contains("ProgressView()"))
        #expect(controls.contains(".accessibilityHidden(true)"))
    }

    @Test("OSC and recent-link begin identity-keyed progress")
    func terminalOriginsBeginCoordinator() throws {
        let source = try SourceContract.source(
            at: "Sources/awesoMux/Services/GhosttyRuntime+OpenURL.swift"
        )
        #expect(source.contains("progress.begin("))
        #expect(source.contains("Origin.surface(paneID: paneID)"))
        #expect(source.contains("announceRemoteMarkdownLoading()"))
        #expect(!source.contains("presentRemoteMarkdownFetchProgress"))
    }

    @Test("surface spinner uses the unified loading copy")
    func surfaceSpinnerUsesUnifiedLoadingCopy() throws {
        let source = try SourceContract.source(
            at: "Sources/awesoMux/Views/GhosttySurface/GhosttySurfaceNSView.swift"
        )
        #expect(
            source.contains(
                "TerminalAccessibilityAnnouncer.remoteMarkdownLoadingAnnouncement"
            )
        )
        #expect(!source.contains("Loading document"))
    }

    @Test("document overlay uses the unified loading copy")
    func documentOverlayUsesUnifiedLoadingCopy() throws {
        let source = try SourceContract.source(
            at: "Sources/awesoMux/Views/RemoteMarkdownFetchProgressOverlay.swift"
        )
        #expect(
            source.contains("TerminalAccessibilityAnnouncer.remoteMarkdownLoadingAnnouncement")
        )
        #expect(source.contains("allowsHitTesting(false)"))
    }
}
