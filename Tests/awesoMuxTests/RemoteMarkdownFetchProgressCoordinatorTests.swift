import AwesoMuxCore
import AwesoMuxTestSupport
import Foundation
import Testing

@testable import awesoMux

@MainActor
@Suite("Remote Markdown fetch progress coordinator")
struct RemoteMarkdownFetchProgressCoordinatorTests {
    private func makeIdentity(path: String = "/repo/doc.md") -> ResourceIdentity {
        ResourceIdentity(
            location: .remote(RemoteTarget(parsing: "devbox")!),
            path: ResourcePath(rawValue: path)
        )
    }

    @Test("first waiter returns true; coalesced waiter returns false")
    func firstWaiterIsDistinguished() {
        let progress = RemoteMarkdownFetchProgressCoordinator()
        let sessionID = UUID()
        let identity = makeIdentity()
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
        #expect(progress.isDocumentOverlayBusy(sessionID: sessionID, identity: identity))
        progress.finish(sessionID: sessionID, identity: identity, origin: .document)
        #expect(!progress.isInFlight(sessionID: sessionID, identity: identity))
        #expect(!progress.isDocumentOverlayBusy(sessionID: sessionID, identity: identity))
    }

    @Test("surface and document origins do not share chrome")
    func surfaceAndDocumentOriginsAreIndependent() {
        let progress = RemoteMarkdownFetchProgressCoordinator()
        let sessionID = UUID()
        let paneID = UUID()
        let identity = makeIdentity()
        _ = progress.begin(
            sessionID: sessionID,
            identity: identity,
            origin: .surface(paneID: paneID)
        )
        #expect(progress.isSurfaceBusy(sessionID: sessionID, paneID: paneID))
        #expect(!progress.isDocumentOverlayBusy(sessionID: sessionID, identity: identity))
        let documentIdentity = makeIdentity(path: "/repo/other.md")
        _ = progress.begin(
            sessionID: sessionID,
            identity: documentIdentity,
            origin: .document
        )
        #expect(progress.isDocumentOverlayBusy(sessionID: sessionID, identity: documentIdentity))
        progress.finish(
            sessionID: sessionID,
            identity: identity,
            origin: .surface(paneID: paneID)
        )
        #expect(!progress.isSurfaceBusy(sessionID: sessionID, paneID: paneID))
        #expect(progress.isDocumentOverlayBusy(sessionID: sessionID, identity: documentIdentity))
    }

    @Test("Refresh shares ownership without adding document overlay chrome")
    func refreshOriginDoesNotAddChrome() {
        let progress = RemoteMarkdownFetchProgressCoordinator()
        let sessionID = UUID()
        let identity = makeIdentity()

        #expect(progress.begin(sessionID: sessionID, identity: identity, origin: .refresh))
        #expect(progress.isInFlight(sessionID: sessionID, identity: identity))
        #expect(!progress.isDocumentOverlayBusy(sessionID: sessionID, identity: identity))
        progress.finish(sessionID: sessionID, identity: identity, origin: .refresh)
        #expect(!progress.isInFlight(sessionID: sessionID, identity: identity))
    }

    @Test("different sessions and identities do not block each other")
    func keysAreIndependent() {
        let progress = RemoteMarkdownFetchProgressCoordinator()
        let firstSession = UUID()
        let secondSession = UUID()
        let first = makeIdentity()
        let second = makeIdentity(path: "/repo/other.md")
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
            identity: makeIdentity(),
            origin: .surface(paneID: paneID)
        )
        #expect(presenter.isBusy)

        presenter.isBusy = false
        progress.registerSurface(presenter, sessionID: sessionID, paneID: paneID)
        #expect(presenter.isBusy)

        progress.finish(
            sessionID: sessionID,
            identity: makeIdentity(),
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
            identity: makeIdentity(),
            origin: .surface(paneID: firstPane)
        )
        progress.registerSurface(presenter, sessionID: sessionID, paneID: firstPane)
        #expect(presenter.isBusy)

        progress.registerSurface(presenter, sessionID: sessionID, paneID: secondPane)
        #expect(!presenter.isBusy)

        _ = progress.begin(
            sessionID: sessionID,
            identity: makeIdentity(path: "/repo/other.md"),
            origin: .surface(paneID: secondPane)
        )
        #expect(presenter.isBusy)
    }

    @Test("document overlay follows fetch identity and source pin, not the session")
    func documentOverlayIsIdentityScoped() {
        let progress = RemoteMarkdownFetchProgressCoordinator()
        let sessionID = UUID()
        let source = makeIdentity(path: "/repo/docs/README.md")
        let destination = makeIdentity(path: "/repo/docs/sibling.md")
        let unrelated = makeIdentity(path: "/repo/other.md")
        _ = progress.begin(
            sessionID: sessionID,
            identity: destination,
            origin: .document,
            overlayIdentity: source
        )
        #expect(progress.isDocumentOverlayBusy(sessionID: sessionID, identity: source))
        #expect(progress.isDocumentOverlayBusy(sessionID: sessionID, identity: destination))
        #expect(!progress.isDocumentOverlayBusy(sessionID: sessionID, identity: unrelated))
        progress.finish(
            sessionID: sessionID,
            identity: destination,
            origin: .document,
            overlayIdentity: source
        )
        #expect(!progress.isDocumentOverlayBusy(sessionID: sessionID, identity: source))
        #expect(!progress.isDocumentOverlayBusy(sessionID: sessionID, identity: destination))
    }

    @Test("finish without a matching begin does not decrement another origin's count")
    func finishWithoutBeginDoesNotDecrementSharedCount() {
        let progress = RemoteMarkdownFetchProgressCoordinator()
        let sessionID = UUID()
        let paneID = UUID()
        let identity = makeIdentity()
        progress.finish(sessionID: sessionID, identity: identity, origin: .document)
        #expect(!progress.isInFlight(sessionID: sessionID, identity: identity))

        _ = progress.begin(sessionID: sessionID, identity: identity, origin: .document)
        progress.finish(
            sessionID: sessionID,
            identity: identity,
            origin: .surface(paneID: paneID)
        )
        #expect(progress.isInFlight(sessionID: sessionID, identity: identity))
        #expect(progress.isDocumentOverlayBusy(sessionID: sessionID, identity: identity))
        progress.finish(sessionID: sessionID, identity: identity, origin: .document)
        #expect(!progress.isInFlight(sessionID: sessionID, identity: identity))
        #expect(!progress.isDocumentOverlayBusy(sessionID: sessionID, identity: identity))
    }

    private final class FakeSurfacePresenter: RemoteMarkdownFetchProgressSurfacePresenting {
        var isBusy = false

        func syncRemoteMarkdownFetchProgress(isBusy: Bool) {
            self.isBusy = isBusy
        }
    }
}

@MainActor
@Suite("Remote Markdown fetch progress wiring", .serialized)
struct RemoteMarkdownFetchProgressWiringTests {
    @Test("Md→Md announces loading and outcome only for the first waiter")
    func documentLinkFirstWaiterOnlyAnnouncesLoadingAndOutcome() async throws {
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
        let destination = try #require(
            RemoteMarkdownDocumentLinkNavigation.reference(
                forOpenedLinkURL: link,
                from: source
            )?.identity
        )
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-md-progress-\(UUID().uuidString).md")
        try "# sibling\n".write(to: cacheURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        let progress = RemoteMarkdownFetchProgressCoordinator()
        let hold = AsyncGate()
        var loadingCount = 0
        var outcomeCount = 0

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

        // Disable the Md→Md link latch so this test can exercise progress
        // coalescing; link-drop behavior lives in DocumentLinkNavigationTests.
        let first = Task { @MainActor in
            await RemoteMarkdownDocumentLinkNavigation.open(
                url: link,
                from: source,
                in: sessionID,
                associatedWith: nil,
                sessionStore: store,
                coordinator: nil,
                fetch: { reference in
                    await hold.wait()
                    return outcome(for: reference)
                },
                onAnnounceLoading: { loadingCount += 1 },
                onAnnounceOutcome: { _ in outcomeCount += 1 },
                progress: progress
            )
        }

        #expect(
            await waitUntilEventually {
                progress.isDocumentOverlayBusy(sessionID: sessionID, identity: source)
                    && progress.isDocumentOverlayBusy(sessionID: sessionID, identity: destination)
            }
        )
        #expect(loadingCount == 1)

        let secondID = await RemoteMarkdownDocumentLinkNavigation.open(
            url: link,
            from: source,
            in: sessionID,
            associatedWith: nil,
            sessionStore: store,
            coordinator: nil,
            fetch: { reference in
                hold.open()
                return outcome(for: reference)
            },
            onAnnounceLoading: { loadingCount += 1 },
            onAnnounceOutcome: { _ in outcomeCount += 1 },
            progress: progress
        )

        _ = await first.value
        #expect(secondID != nil)
        #expect(loadingCount == 1)
        #expect(outcomeCount == 1)
        #expect(!progress.isDocumentOverlayBusy(sessionID: sessionID, identity: source))
        #expect(!progress.isDocumentOverlayBusy(sessionID: sessionID, identity: destination))
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
        #expect(RemoteMarkdownTypedPathOpen.overlayIdentity(for: snapshotSession) == identity)
        #expect(RemoteMarkdownTypedPathOpen.overlayIdentity(for: sshSession) == nil)
    }

    @Test("announceLoadingIfValid begins and stays silent for a coalesced waiter")
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
        let claim = RemoteMarkdownTypedPathOpen.announceLoadingIfValid(
            typedPath: "/repo/NOTES.md",
            target: target,
            sessionID: sessionID,
            origin: .document,
            progress: progress,
            onAnnounceLoading: { announcements += 1 }
        )
        #expect(claim != nil)
        #expect(claim?.isFirstWaiter == false)
        #expect(announcements == 0)
        progress.finish(sessionID: sessionID, identity: identity, origin: .document)
        if let claim {
            progress.finish(claim)
        }
        #expect(!progress.isInFlight(sessionID: sessionID, identity: identity))
    }

    @Test("announceLoadingIfValid begins before dismiss; open adopts without a second begin")
    func typedPathBeginHappensBeforeDismiss() async throws {
        let target = RemoteTarget(parsing: "my-purple")!
        let progress = RemoteMarkdownFetchProgressCoordinator()
        let store = SessionStore()
        let sessionID = store.addSession(workingDirectory: "/tmp")
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-md-begin-before-dismiss-\(UUID().uuidString).md")
        try "# notes\n".write(to: cacheURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        var events: [String] = []
        let identity = ResourceIdentity(
            location: .remote(target),
            path: ResourcePath(rawValue: "/repo/NOTES.md")
        )
        let claim = RemoteMarkdownTypedPathOpen.announceLoadingIfValid(
            typedPath: "/repo/NOTES.md",
            target: target,
            sessionID: sessionID,
            origin: .document,
            progress: progress,
            onAnnounceLoading: { events.append("loading") }
        )
        let resolvedClaim = try #require(claim)
        #expect(resolvedClaim.isFirstWaiter)
        #expect(progress.isInFlight(sessionID: sessionID, identity: identity))
        events.append("dismiss")

        let openedID = try #require(
            await RemoteMarkdownTypedPathOpen.open(
                typedPath: "/repo/NOTES.md",
                target: target,
                in: sessionID,
                associatedWith: nil,
                sessionStore: store,
                fetch: { reference in
                    events.append("fetch:\(reference.remotePath)")
                    return .fresh(
                        RemoteMarkdownSnapshot(
                            fileURL: cacheURL,
                            identity: ResourceIdentity(
                                location: reference.identity.location,
                                path: ResourcePath(rawValue: reference.remotePath)
                            )
                        )
                    )
                },
                onAnnounceLoading: { events.append("loading-again") },
                onAnnounceOutcome: { _ in events.append("outcome") },
                progressClaim: resolvedClaim,
                progress: progress
            )
        )
        #expect(!progress.isInFlight(sessionID: sessionID, identity: identity))
        #expect(
            events == [
                "loading",
                "dismiss",
                "fetch:/repo/NOTES.md",
                "outcome",
            ]
        )
    }

    @Test("typed-path outcome is first-waiter only")
    func typedPathOutcomeIsFirstWaiterOnly() async throws {
        let target = RemoteTarget(parsing: "my-purple")!
        let progress = RemoteMarkdownFetchProgressCoordinator()
        let store = SessionStore()
        let sessionID = store.addSession(workingDirectory: "/tmp")
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-md-typed-outcome-\(UUID().uuidString).md")
        try "# notes\n".write(to: cacheURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        let hold = AsyncGate()
        var loadingCount = 0
        var outcomeCount = 0

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
            await RemoteMarkdownTypedPathOpen.open(
                typedPath: "/repo/NOTES.md",
                target: target,
                in: sessionID,
                associatedWith: nil,
                sessionStore: store,
                fetch: { reference in
                    await hold.wait()
                    return outcome(for: reference)
                },
                onAnnounceLoading: { loadingCount += 1 },
                onAnnounceOutcome: { _ in outcomeCount += 1 },
                origin: .document,
                progress: progress
            )
        }

        #expect(
            await waitUntil {
                progress.isInFlight(
                    sessionID: sessionID,
                    identity: ResourceIdentity(
                        location: .remote(target),
                        path: ResourcePath(rawValue: "/repo/NOTES.md")
                    )
                )
            }
        )

        let secondID = await RemoteMarkdownTypedPathOpen.open(
            typedPath: "/repo/NOTES.md",
            target: target,
            in: sessionID,
            associatedWith: nil,
            sessionStore: store,
            fetch: { reference in
                hold.open()
                return outcome(for: reference)
            },
            onAnnounceLoading: { loadingCount += 1 },
            onAnnounceOutcome: { _ in outcomeCount += 1 },
            origin: .document,
            progress: progress
        )

        _ = await first.value
        #expect(secondID != nil)
        #expect(loadingCount == 1)
        #expect(outcomeCount == 1)
    }

    @Test("typed-path open uses a frozen origin instead of live selection")
    func typedPathOpenUsesFrozenOrigin() async throws {
        let target = RemoteTarget(parsing: "my-purple")!
        let progress = RemoteMarkdownFetchProgressCoordinator()
        let store = SessionStore()
        let sessionID = store.addSession(workingDirectory: "/tmp")
        let snapshotIdentity = ResourceIdentity(
            location: .remote(target),
            path: ResourcePath(rawValue: "/repo/README.md")
        )
        let paneID = UUID()
        #expect(
            RemoteMarkdownTypedPathOpen.fetchProgressOrigin(
                for: store.session(id: sessionID)!
            ) != .surface(paneID: paneID)
        )

        let hold = AsyncGate()
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-md-frozen-origin-\(UUID().uuidString).md")
        try "# notes\n".write(to: cacheURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        let openTask = Task { @MainActor in
            await RemoteMarkdownTypedPathOpen.open(
                typedPath: "/repo/NOTES.md",
                target: target,
                in: sessionID,
                associatedWith: paneID,
                sessionStore: store,
                fetch: { _ in
                    await hold.wait()
                    return .fresh(
                        RemoteMarkdownSnapshot(
                            fileURL: cacheURL,
                            identity: ResourceIdentity(
                                location: .remote(target),
                                path: ResourcePath(rawValue: "/repo/NOTES.md")
                            )
                        )
                    )
                },
                onAnnounceLoading: {},
                origin: .surface(paneID: paneID),
                progress: progress
            )
        }

        #expect(
            await waitUntil {
                progress.isSurfaceBusy(sessionID: sessionID, paneID: paneID)
            }
        )
        #expect(!progress.isDocumentOverlayBusy(sessionID: sessionID, identity: snapshotIdentity))
        hold.open()
        _ = await openTask.value
        #expect(!progress.isSurfaceBusy(sessionID: sessionID, paneID: paneID))
    }
}

@Suite("Remote Markdown fetch progress source contracts")
struct RemoteMarkdownFetchProgressSourceContractTests {
    @Test("document overlay sits outside remount identity and is identity-scoped")
    func documentOverlayDoesNotChangeRemountIdentity() throws {
        let source = try SourceContract.source(at: "Sources/awesoMux/Views/DocumentGroupView.swift")
        #expect(source.contains(".id(DocumentPaneContentIdentity.remountID(for: document))"))
        #expect(source.contains("RemoteMarkdownFetchProgressOverlayHost("))
        #expect(source.contains("identity: document.remoteResourceIdentity"))
        #expect(!source.contains("isDocumentBusy("))
        #expect(!source.contains("@Environment(RemoteMarkdownFetchProgressCoordinator.self)"))
        let remountIndex = try #require(
            source.range(of: ".id(DocumentPaneContentIdentity.remountID(for: document))")
        )
        let overlayIndex = try #require(
            source.range(of: "RemoteMarkdownFetchProgressOverlayHost(")
        )
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
        let overlay = try SourceContract.declarationBody(
            after: "struct RemoteMarkdownFetchProgressOverlay: View {",
            in: source,
            path: "Sources/awesoMux/Views/RemoteMarkdownFetchProgressOverlay.swift"
        )
        #expect(
            overlay.contains("TerminalAccessibilityAnnouncer.remoteMarkdownLoadingAnnouncement")
        )
        #expect(overlay.contains("allowsHitTesting(false)"))
        #expect(overlay.contains(".accessibilityHidden(true)"))
        #expect(!overlay.contains("accessibilityElement(children: .ignore)"))
        #expect(source.contains("RemoteMarkdownFetchProgressOverlayHost"))
        #expect(source.contains("documentOverlayKeys"))
    }

    @Test("surface spinner recreates when the indicator is detached from its superview")
    func surfaceSpinnerTreatsDetachedIndicatorAsMissing() throws {
        let source = try SourceContract.source(
            at: "Sources/awesoMux/Views/GhosttySurface/GhosttySurfaceNSView.swift"
        )
        let sync = try SourceContract.declarationBody(
            after: "func syncRemoteMarkdownFetchProgress(isBusy: Bool) {",
            in: source,
            path: "Sources/awesoMux/Views/GhosttySurface/GhosttySurfaceNSView.swift"
        )
        #expect(sync.contains("existing.superview === self"))
        #expect(sync.contains("clearRemoteMarkdownFetchProgress()"))
    }

    @Test("discardAllSurfaces unregisters progress presenters")
    func discardAllSurfacesUnregistersPresenters() throws {
        let source = try SourceContract.source(at: "Sources/awesoMux/Services/GhosttyRuntime.swift")
        let body = try SourceContract.declarationBody(
            after: "func discardAllSurfaces() {",
            in: source,
            path: "Sources/awesoMux/Services/GhosttyRuntime.swift"
        )
        #expect(body.contains("unregisterSurface(surfaceView)"))
    }

    @Test("typed-path sheet begins before dismiss and adopts the claim")
    func typedPathSheetBeginsBeforeDismiss() throws {
        let source = try SourceContract.source(at: "Sources/awesoMux/App/AwesoMuxApp.swift")
        let onOpen = try SourceContract.declarationBody(
            after: "onOpen: { path in",
            in: source,
            path: "Sources/awesoMux/App/AwesoMuxApp.swift"
        )
        #expect(onOpen.contains("announceLoadingIfValid("))
        #expect(onOpen.contains("progressClaim: claim"))
        let announceIndex = try #require(onOpen.range(of: "announceLoadingIfValid("))
        let dismissIndex = try #require(onOpen.range(of: "remoteMarkdownPathOpenRequest = nil"))
        let adoptIndex = try #require(onOpen.range(of: "progressClaim: claim"))
        #expect(announceIndex.lowerBound < dismissIndex.lowerBound)
        #expect(dismissIndex.lowerBound < adoptIndex.lowerBound)
    }

    @Test("Md→Md and typed-path gate outcome on the first waiter")
    func documentOriginOutcomeIsFirstWaiterOnly() throws {
        let documentLink = try SourceContract.source(
            at: "Sources/awesoMux/Services/RemoteMarkdownDocumentLinkNavigation.swift"
        )
        #expect(documentLink.contains("onAnnounceOutcome(outcome)"))
        #expect(documentLink.contains("overlayIdentity: source"))
        let typedPath = try SourceContract.source(
            at: "Sources/awesoMux/Services/RemoteMarkdownTypedPathOpen.swift"
        )
        #expect(typedPath.contains("if claim.isFirstWaiter"))
        #expect(typedPath.contains("onAnnounceOutcome(outcome)"))
    }
}
