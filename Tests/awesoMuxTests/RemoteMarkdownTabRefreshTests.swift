import AwesoMuxCore
import Dispatch
import Foundation
import Testing

@testable import awesoMux

@MainActor
@Suite("Remote Markdown tab refresh", .serialized)
struct RemoteMarkdownTabRefreshTests {
    private final class FetchGate: @unchecked Sendable {
        private let lock = NSLock()
        private var started: CheckedContinuation<Void, Never>?
        private var release: CheckedContinuation<Void, Never>?
        private var hasStarted = false
        private var isReleased = false

        func wait() async {
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

        func open() {
            lock.lock()
            isReleased = true
            let release = release
            self.release = nil
            lock.unlock()
            release?.resume()
        }

        private func markStarted() {
            lock.lock()
            hasStarted = true
            let started = started
            self.started = nil
            lock.unlock()
            started?.resume()
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

    private func remoteIdentity(path: String = "/repo/doc.md") -> ResourceIdentity {
        ResourceIdentity(
            location: .remote(RemoteTarget(parsing: "devbox")!),
            path: ResourcePath(rawValue: path)
        )
    }

    private func snapshot(
        path: String,
        identity: ResourceIdentity
    ) -> RemoteMarkdownSnapshot {
        RemoteMarkdownSnapshot(
            fileURL: URL(fileURLWithPath: path),
            identity: identity
        )
    }

    private func storeWithRemoteTab(
        identity: ResourceIdentity,
        cacheURL: URL
    ) throws -> (store: SessionStore, sessionID: TerminalSession.ID, tabID: DocumentPane.ID) {
        let store = SessionStore()
        let sessionID = store.addSession(workingDirectory: "/tmp")
        let session = try #require(store.session(id: sessionID))
        let terminalID = session.activePaneID
        let tabID = try #require(
            store.openDocumentPane(
                fileURL: cacheURL,
                in: sessionID,
                associatedWith: terminalID,
                remoteResourceIdentity: identity
            ))
        return (store, sessionID, tabID)
    }

    @Test("restore without opt-in keeps saved tabs and never fetches")
    func restoreWithoutOptInKeepsSavedCopy() async throws {
        let path = "/tmp/restore-opt-out-\(UUID()).md"
        let (store, sessionID, tabID) = try storeWithRemoteTab(identity: remoteIdentity(), cacheURL: URL(fileURLWithPath: path))
        defer { RemoteSnapshotStalePolicy.note(nil, path: path) }
        let localPath = "/tmp/local-\(UUID()).md"
        _ = store.openDocumentPane(fileURL: URL(fileURLWithPath: localPath), in: sessionID)
        let before = store.groups
        var fetches = 0
        RemoteMarkdownTabRefresh.scheduleRestoreRefresh(for: store, automaticallyRefresh: false) { _ in
            fetches += 1
            return nil
        }
        // Banner seeding must happen synchronously, before the restored view mounts.
        #expect(RemoteSnapshotStalePolicy.bannerKind(path: path) == .remoteNotRefreshed)
        #expect(RemoteSnapshotStalePolicy.bannerKind(path: localPath) == nil)
        #expect(fetches == 0)
        #expect(store.groups == before)

        // Manual Refresh still fetches when automatic launch fetch is off.
        let outcome = await RemoteMarkdownTabRefresh.refresh(
            identity: remoteIdentity(), documentID: tabID, in: sessionID,
            associatedWith: nil, sessionStore: store, selectingTab: false,
            fetch: { reference in
                fetches += 1
                return .fresh(RemoteMarkdownSnapshot(fileURL: URL(fileURLWithPath: path), identity: reference.identity))
            }
        )
        #expect(outcome != nil)
        #expect(fetches == 1)
        #expect(RemoteSnapshotStalePolicy.bannerKind(path: path) == nil)
    }

    @Test("restore without opt-in leaves failure pages without a saved-copy banner")
    func restoreWithoutOptInPreservesFailurePage() throws {
        let path = "/tmp/restore-opt-out-\(UUID()).failure.md"
        let (store, _, _) = try storeWithRemoteTab(identity: remoteIdentity(), cacheURL: URL(fileURLWithPath: path))
        RemoteMarkdownTabRefresh.scheduleRestoreRefresh(for: store, automaticallyRefresh: false)
        #expect(RemoteSnapshotStalePolicy.bannerKind(path: path) == nil)
    }

    private let refreshFailedMessage =
        "Remote Markdown refresh failed. Showing the saved cached copy, which may be stale."

    /// Captures announcer output and can await one specific message, so a test
    /// can assert on the fire-and-forget restore sweep deterministically. The
    /// announcer poster is global and parallel suites post through it, so
    /// assertions count the sentence under test rather than the whole log.
    private final class AnnouncementProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var messages: [String] = []

        func record(_ message: String) {
            lock.lock()
            messages.append(message)
            lock.unlock()
        }

        func count(of message: String) -> Int {
            lock.lock()
            defer { lock.unlock() }
            return messages.filter { $0 == message }.count
        }
    }

    @Test("restore targets collect every remote Markdown tab and skip local docs")
    func restoreTargetsCollectRemoteTabsOnly() throws {
        let store = SessionStore()
        let sessionID = store.addSession(workingDirectory: "/tmp")
        let session = try #require(store.session(id: sessionID))
        let terminalID = session.activePaneID
        let remoteIdentity = remoteIdentity()
        let cacheURL = URL(fileURLWithPath: "/tmp/remote-cache-\(UUID().uuidString).md")
        let tabID = try #require(
            store.openDocumentPane(
                fileURL: cacheURL,
                in: sessionID,
                associatedWith: terminalID,
                remoteResourceIdentity: remoteIdentity
            ))
        _ = store.openDocumentPane(
            fileURL: URL(fileURLWithPath: "/tmp/local-\(UUID().uuidString).md"),
            in: sessionID,
            associatedWith: terminalID
        )

        let targets = RemoteMarkdownTabRefresh.restoreTargets(in: store)

        #expect(targets.count == 1)
        #expect(targets[0].sessionID == sessionID)
        #expect(targets[0].documentID == tabID)
        #expect(targets[0].identity == remoteIdentity)
        #expect(targets[0].associatedTerminalPaneID == terminalID)
    }

    @Test("apply records the outcome through RemoteSnapshotStalePolicy")
    func applyRecordsThroughStalePolicy() throws {
        let identity = remoteIdentity()
        let path = "/tmp/awesomux-refresh-\(UUID().uuidString).md"
        defer { RemoteSnapshotStalePolicy.note(nil, path: path) }
        let (store, sessionID, _) = try storeWithRemoteTab(
            identity: identity,
            cacheURL: URL(fileURLWithPath: path)
        )

        RemoteMarkdownTabRefresh.apply(
            .cached(snapshot(path: path, identity: identity), staleReason: .oversize),
            in: sessionID,
            associatedWith: nil,
            sessionStore: store,
            selectingTab: false
        )

        #expect(
            RemoteSnapshotStalePolicy.bannerKind(path: path) == .remoteStoppedRefreshing)
    }

    @Test("apply with selectingTab false leaves the selected tab alone")
    func applyDoesNotStealSelection() throws {
        let identityA = remoteIdentity(path: "/repo/a.md")
        let identityB = remoteIdentity(path: "/repo/b.md")
        let pathA = "/tmp/awesomux-refresh-a-\(UUID().uuidString).md"
        let pathB = "/tmp/awesomux-refresh-b-\(UUID().uuidString).md"
        defer {
            RemoteSnapshotStalePolicy.note(nil, path: pathA)
            RemoteSnapshotStalePolicy.note(nil, path: pathB)
        }

        let store = SessionStore()
        let sessionID = store.addSession(workingDirectory: "/tmp")
        let session = try #require(store.session(id: sessionID))
        let terminalID = session.activePaneID
        let tabA = try #require(
            store.openDocumentPane(
                fileURL: URL(fileURLWithPath: pathA),
                in: sessionID,
                associatedWith: terminalID,
                remoteResourceIdentity: identityA
            ))
        let tabB = try #require(
            store.openDocumentPane(
                fileURL: URL(fileURLWithPath: pathB),
                in: sessionID,
                associatedWith: terminalID,
                remoteResourceIdentity: identityB
            ))
        // Applying B without selecting must leave A selected so this
        // assertion catches a selection steal.
        store.selectDocumentTab(tabID: tabA, in: sessionID)
        #expect(
            store.session(id: sessionID)?.layout.firstDocumentGroup?.selectedTabID == tabA)

        RemoteMarkdownTabRefresh.apply(
            .fresh(snapshot(path: pathB, identity: identityB)),
            in: sessionID,
            associatedWith: terminalID,
            sessionStore: store,
            selectingTab: false
        )

        #expect(
            store.session(id: sessionID)?.layout.firstDocumentGroup?.selectedTabID == tabA)
        #expect(tabB != tabA)
    }

    @Test("selecting apply heals a dead association; restore apply preserves nil")
    func applyHealsDeadAssociationOnlyWhenSelecting() throws {
        let identityLive = remoteIdentity(path: "/repo/live.md")
        let identityRestore = remoteIdentity(path: "/repo/restore.md")
        let pathLive = "/tmp/awesomux-refresh-heal-\(UUID().uuidString).md"
        let pathRestore = "/tmp/awesomux-refresh-preserve-\(UUID().uuidString).md"
        defer {
            RemoteSnapshotStalePolicy.note(nil, path: pathLive)
            RemoteSnapshotStalePolicy.note(nil, path: pathRestore)
        }

        let store = SessionStore()
        let sessionID = store.addSession(workingDirectory: "/tmp")
        let session = try #require(store.session(id: sessionID))
        let terminalID = session.activePaneID
        // Restore remaps a missing pane id to nil; that is the dead
        // association footer Refresh and restore re-fetch both see.
        let liveTab = try #require(
            store.openDocumentPane(
                fileURL: URL(fileURLWithPath: pathLive),
                in: sessionID,
                associatedWith: nil,
                remoteResourceIdentity: identityLive,
                associationPolicy: .preserveNil
            ))
        let restoreTab = try #require(
            store.openDocumentPane(
                fileURL: URL(fileURLWithPath: pathRestore),
                in: sessionID,
                associatedWith: nil,
                remoteResourceIdentity: identityRestore,
                associationPolicy: .preserveNil
            ))
        #expect(
            store.session(id: sessionID)?.layout.firstDocumentGroup?
                .tab(id: liveTab)?.associatedTerminalPaneID == nil)
        #expect(
            store.session(id: sessionID)?.layout.firstDocumentGroup?
                .tab(id: restoreTab)?.associatedTerminalPaneID == nil)

        RemoteMarkdownTabRefresh.apply(
            .fresh(snapshot(path: pathLive, identity: identityLive)),
            in: sessionID,
            associatedWith: nil,
            sessionStore: store,
            selectingTab: true
        )
        RemoteMarkdownTabRefresh.apply(
            .fresh(snapshot(path: pathRestore, identity: identityRestore)),
            in: sessionID,
            associatedWith: nil,
            sessionStore: store,
            selectingTab: false
        )

        let group = try #require(store.session(id: sessionID)?.layout.firstDocumentGroup)
        #expect(group.tab(id: liveTab)?.associatedTerminalPaneID == terminalID)
        #expect(group.tab(id: restoreTab)?.associatedTerminalPaneID == nil)
    }

    @Test("refresh refuses a closed tab and does not reopen it")
    func refreshIgnoresClosedTab() async throws {
        let identity = remoteIdentity()
        let path = "/tmp/awesomux-refresh-closed-\(UUID().uuidString).md"
        defer { RemoteSnapshotStalePolicy.note(nil, path: path) }
        let (store, sessionID, tabID) = try storeWithRemoteTab(
            identity: identity,
            cacheURL: URL(fileURLWithPath: path)
        )
        store.closeDocumentPane(documentID: tabID, in: sessionID)
        #expect(store.session(id: sessionID)?.layout.firstDocumentGroup == nil)

        let outcome = await RemoteMarkdownTabRefresh.refresh(
            identity: identity,
            documentID: tabID,
            in: sessionID,
            associatedWith: nil,
            sessionStore: store,
            selectingTab: false,
            fetch: { _ in
                .fresh(snapshot(path: path, identity: identity))
            }
        )

        #expect(outcome == nil)
        #expect(store.session(id: sessionID)?.layout.firstDocumentGroup == nil)
        #expect(RemoteSnapshotStalePolicy.bannerKind(path: path) == nil)
    }

    @Test("refresh applies a failure document to the open tab")
    func refreshAppliesFailureDocument() async throws {
        let identity = remoteIdentity()
        let path = "/tmp/awesomux-refresh-ok-\(UUID().uuidString).md"
        let failurePath = "/tmp/awesomux-refresh-fail-\(UUID().uuidString).failure.md"
        defer {
            RemoteSnapshotStalePolicy.note(nil, path: path)
            RemoteSnapshotStalePolicy.note(nil, path: failurePath)
        }
        let (store, sessionID, tabID) = try storeWithRemoteTab(
            identity: identity,
            cacheURL: URL(fileURLWithPath: path)
        )

        let outcome = await RemoteMarkdownTabRefresh.refresh(
            identity: identity,
            documentID: tabID,
            in: sessionID,
            associatedWith: nil,
            sessionStore: store,
            selectingTab: false,
            fetch: { _ in
                .failureDocument(
                    snapshot(path: failurePath, identity: identity),
                    reason: .connection
                )
            }
        )

        #expect(outcome != nil)
        let tab = try #require(
            store.session(id: sessionID)?.layout.firstDocumentGroup?.tab(id: tabID))
        #expect(tab.fileURL.standardizedFileURL.path == failurePath)
        #expect(RemoteSnapshotStalePolicy.bannerKind(path: failurePath) == nil)
    }

    @Test("a nil fetch outcome notes refresh-failed for the stale banner")
    func nilFetchOutcomeNotesPolicy() async throws {
        let identity = remoteIdentity()
        let path = "/tmp/awesomux-refresh-nil-\(UUID().uuidString).md"
        defer { RemoteSnapshotStalePolicy.note(nil, path: path) }
        let (store, sessionID, tabID) = try storeWithRemoteTab(
            identity: identity,
            cacheURL: URL(fileURLWithPath: path)
        )

        let outcome = await RemoteMarkdownTabRefresh.refresh(
            identity: identity,
            documentID: tabID,
            in: sessionID,
            associatedWith: nil,
            sessionStore: store,
            selectingTab: true,
            announceOutcome: false,
            fetch: { _ in nil }
        )

        #expect(outcome == nil)
        #expect(RemoteSnapshotStalePolicy.bannerKind(path: path) == .remoteRefreshFailed)
        #expect(
            store.session(id: sessionID)?.layout.firstDocumentGroup?
                .tab(forRemoteResource: identity)?.fileURL.standardizedFileURL.path == path)
    }

    @Test("a nil fetch after the tab closed does not note policy")
    func nilFetchOnClosedTabIsSilent() async throws {
        let identity = remoteIdentity()
        let path = "/tmp/awesomux-refresh-nil-closed-\(UUID().uuidString).md"
        defer { RemoteSnapshotStalePolicy.note(nil, path: path) }
        let (store, sessionID, tabID) = try storeWithRemoteTab(
            identity: identity,
            cacheURL: URL(fileURLWithPath: path)
        )

        let outcome = await RemoteMarkdownTabRefresh.refresh(
            identity: identity,
            documentID: tabID,
            in: sessionID,
            associatedWith: nil,
            sessionStore: store,
            selectingTab: true,
            fetch: { _ in
                store.closeDocumentPane(documentID: tabID, in: sessionID)
                return nil
            }
        )

        #expect(outcome == nil)
        #expect(RemoteSnapshotStalePolicy.bannerKind(path: path) == nil)
    }

    @Test("scheduleRestoreRefresh kicks one fetch per remote tab")
    func scheduleRestoreRefreshFetchesEachRemoteTab() async throws {
        let identityA = remoteIdentity(path: "/repo/a.md")
        let identityB = remoteIdentity(path: "/repo/b.md")
        let pathA = "/tmp/awesomux-restore-a-\(UUID().uuidString).md"
        let pathB = "/tmp/awesomux-restore-b-\(UUID().uuidString).md"
        defer {
            RemoteSnapshotStalePolicy.note(nil, path: pathA)
            RemoteSnapshotStalePolicy.note(nil, path: pathB)
        }

        let store = SessionStore()
        let sessionID = store.addSession(workingDirectory: "/tmp")
        let session = try #require(store.session(id: sessionID))
        let terminalID = session.activePaneID
        _ = store.openDocumentPane(
            fileURL: URL(fileURLWithPath: pathA),
            in: sessionID,
            associatedWith: terminalID,
            remoteResourceIdentity: identityA
        )
        _ = store.openDocumentPane(
            fileURL: URL(fileURLWithPath: pathB),
            in: sessionID,
            associatedWith: terminalID,
            remoteResourceIdentity: identityB
        )
        _ = store.openDocumentPane(
            fileURL: URL(fileURLWithPath: "/tmp/local-\(UUID().uuidString).md"),
            in: sessionID,
            associatedWith: terminalID
        )

        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [ResourceIdentity] = []
            private var waiters: [CheckedContinuation<Void, Never>] = []

            func add(_ identity: ResourceIdentity) {
                lock.lock()
                values.append(identity)
                let done = values.count >= 2
                let waiters = done ? self.waiters : []
                if done { self.waiters = [] }
                lock.unlock()
                for waiter in waiters {
                    waiter.resume()
                }
            }

            var snapshot: [ResourceIdentity] {
                lock.lock()
                defer { lock.unlock() }
                return values
            }

            func waitUntilTwo() async {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    lock.lock()
                    if values.count >= 2 {
                        lock.unlock()
                        continuation.resume()
                        return
                    }
                    waiters.append(continuation)
                    lock.unlock()
                }
            }
        }
        let box = Box()
        let (changes, continuation) = AsyncStream<String>.makeStream()
        let observer = NotificationCenter.default.addObserver(
            forName: RemoteSnapshotStalePolicy.didChangeNotification, object: nil, queue: nil
        ) { notification in
            guard let change = notification.object as? RemoteSnapshotStalePolicy.Change,
                change.kind == .remoteStoppedRefreshing,
                change.path == pathA || change.path == pathB
            else { return }
            continuation.yield(change.path)
        }
        let timeout = DispatchWorkItem { continuation.finish() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
        defer {
            timeout.cancel()
            continuation.finish()
            NotificationCenter.default.removeObserver(observer)
        }

        RemoteMarkdownTabRefresh.scheduleRestoreRefresh(for: store, automaticallyRefresh: true) { reference in
            box.add(reference.identity)
            let path = reference.identity.path.rawValue == "/repo/a.md" ? pathA : pathB
            return .cached(
                RemoteMarkdownSnapshot(
                    fileURL: URL(fileURLWithPath: path),
                    identity: reference.identity
                ),
                staleReason: .oversize
            )
        }

        await box.waitUntilTwo()

        var applied: Set<String> = []
        for await path in changes {
            applied.insert(path)
            if applied == Set([pathA, pathB]) { break }
        }
        #expect(applied == Set([pathA, pathB]))

        #expect(Set(box.snapshot) == Set([identityA, identityB]))
        #expect(RemoteSnapshotStalePolicy.bannerKind(path: pathA) == .remoteStoppedRefreshing)
        #expect(RemoteSnapshotStalePolicy.bannerKind(path: pathB) == .remoteStoppedRefreshing)
    }

    @Test("restore admits distinct hosts before queued tabs on the same host")
    func restoreAdmissionInterleavesHosts() async throws {
        let hosts = ["alpha", "alpha", "alpha", "alpha", "beta", "beta", "gamma", "delta"]
        let store = SessionStore()
        let sessionID = store.addSession(workingDirectory: "/tmp")
        let paneID = try #require(store.session(id: sessionID)?.activePaneID)
        var paths: [ResourceIdentity: URL] = [:]
        for (index, host) in hosts.enumerated() {
            let identity = ResourceIdentity(
                location: .remote(try #require(RemoteTarget(parsing: host))),
                path: ResourcePath(rawValue: "/repo/doc-\(index).md")
            )
            let url = URL(fileURLWithPath: "/tmp/restore-fairness-\(UUID().uuidString).md")
            paths[identity] = url
            _ = try #require(
                store.openDocumentPane(
                    fileURL: url, in: sessionID, associatedWith: paneID,
                    remoteResourceIdentity: identity
                ))
        }
        let gates = hosts.map { _ in FetchGate() }
        var started: [ResourceIdentity] = []
        RemoteMarkdownTabRefresh.scheduleRestoreRefresh(for: store, automaticallyRefresh: true) { reference in
            let ordinal = started.count
            started.append(reference.identity)
            await gates[ordinal].wait()
            guard let fileURL = paths[reference.identity] else {
                Issue.record("Restore requested an unregistered resource identity")
                return nil
            }
            return .fresh(
                RemoteMarkdownSnapshot(
                    fileURL: fileURL, identity: reference.identity
                ))
        }
        await gates[3].waitUntilStarted()
        #expect(Set(started.compactMap { $0.remoteTarget?.sshDestination }).count == 4)
        for gate in gates { gate.open() }
        await gates[hosts.count - 1].waitUntilStarted()
        #expect(started.count == hosts.count)
        #expect(Set(started) == Set(paths.keys))
        for host in Set(hosts) {
            let actual = started.filter { $0.remoteTarget?.sshDestination == host }.map(\.path.rawValue)
            let expected = hosts.enumerated().filter { $0.element == host }.map { "/repo/doc-\($0.offset).md" }
            #expect(actual == expected)
        }
    }

    @Test("RemoteMarkdownReference.make(identity:) accepts supported remote Markdown only")
    func makeFromIdentity() {
        #expect(RemoteMarkdownReference.make(identity: remoteIdentity()) != nil)
        #expect(
            RemoteMarkdownReference.make(
                identity: ResourceIdentity(
                    location: .local,
                    path: ResourcePath(rawValue: "/tmp/local.md")
                )
            ) == nil
        )
        #expect(
            RemoteMarkdownReference.make(
                identity: ResourceIdentity(
                    location: .remote(RemoteTarget(parsing: "devbox")!),
                    path: ResourcePath(rawValue: "/repo/notes.txt")
                )
            ) == nil
        )
    }

    @Test("restore marks only the selected tab's target as selected")
    func selectedRestoreTargetIsTheVisibleTab() throws {
        let identity = remoteIdentity()
        let cacheURL = URL(fileURLWithPath: "/tmp/awesomux-restore-selected-\(UUID().uuidString).md")
        let (store, sessionID, _) = try storeWithRemoteTab(identity: identity, cacheURL: cacheURL)
        let target = try #require(RemoteMarkdownTabRefresh.restoreTargets(in: store).first)
        #expect(RemoteMarkdownTabRefresh.isSelectedRestoreTarget(target, in: store))

        // Open a local tab after the remote one: it becomes selected, so the
        // remote target is now a background tab and must not be spoken for.
        let session = try #require(store.session(id: sessionID))
        _ = store.openDocumentPane(
            fileURL: URL(fileURLWithPath: "/tmp/local-\(UUID().uuidString).md"),
            in: sessionID,
            associatedWith: session.activePaneID
        )
        #expect(!RemoteMarkdownTabRefresh.isSelectedRestoreTarget(target, in: store))
    }

    @Test("a nil fetch on a failure-page tab banners and speaks nothing")
    func nilFetchOnFailurePageIsSilent() async throws {
        let identity = remoteIdentity()
        let path = "/tmp/awesomux-failure-page-\(UUID().uuidString).failure.md"
        defer { RemoteSnapshotStalePolicy.note(nil, path: path) }
        let (store, sessionID, tabID) = try storeWithRemoteTab(
            identity: identity,
            cacheURL: URL(fileURLWithPath: path)
        )

        let probe = AnnouncementProbe()
        let previous = TerminalAccessibilityAnnouncer.announcementPoster
        TerminalAccessibilityAnnouncer.setAnnouncementPosterForTesting { message, _ in
            probe.record(message)
        }
        defer { TerminalAccessibilityAnnouncer.setAnnouncementPosterForTesting(previous) }

        _ = await RemoteMarkdownTabRefresh.refresh(
            identity: identity,
            documentID: tabID,
            in: sessionID,
            associatedWith: nil,
            sessionStore: store,
            selectingTab: false,
            announceOutcome: true,
            announceFailure: true,
            fetch: { _ in nil }
        )

        // The tab shows the app-generated failure page, so "showing the last
        // copy that arrived" is not true — neither the banner nor the cue.
        #expect(RemoteSnapshotStalePolicy.bannerKind(path: path) == nil)
        #expect(probe.count(of: refreshFailedMessage) == 0)
    }

    @Test(
        "each live cohort has exactly one outcome speaker",
        arguments: [
            "refreshThenLinkSharesAnnouncementOwnership", "linkThenRefreshSharesAnnouncementOwnership",
            "sameFileNilFetchKeepsLinkFailureAfterTabCloses", "cancelledRefreshDefersNilFailureToSameFileLink",
            "restoreDefersFailureToSameFileLink", "restoreUsesFetchCohortInsteadOfHistoricalDocumentProgress",
            "refreshDefersNilToFailurePresenter", "restoreFailureOwnershipIsSessionScoped", "laterRefreshCohortOwnsSuccess",
            "laterRefreshCohortOwnsFailure", "restoreKeepsSameCohortDocumentPresentationOwnership",
            "restoreDoesNotTakeSameFileLinkSuccessCues", "cancelledRefreshReleasesAnnouncementOwnership",
        ])
    func exactlyOneSpeaker(scenario: String) async throws {
        switch scenario {
        case "refreshThenLinkSharesAnnouncementOwnership":
            let identity = remoteIdentity()
            let source = remoteIdentity(path: "/repo/README.md")
            let link = try #require(
                RemoteMarkdownReference.linkURL(forMarkdownDestination: "doc.md#section", relativeTo: source)
            )
            let cacheURL = URL(fileURLWithPath: "/tmp/awesomux-refresh-race-\(UUID().uuidString).md")
            let (store, sessionID, tabID) = try storeWithRemoteTab(identity: identity, cacheURL: cacheURL)
            _ = try #require(
                store.openDocumentPane(
                    fileURL: cacheURL, in: sessionID, remoteResourceIdentity: source,
                    associationPolicy: .preserveNil, selectingNewTab: false
                ))
            let progress = RemoteMarkdownFetchProgressCoordinator()
            let gate = FetchGate()
            let cohort = RemoteMarkdownFetchCoordinator.Cohort()
            cohort.add(.refresh)
            cohort.add(.document)
            var refreshLoading = 0
            var refreshOutcomes = 0
            var linkLoading = 0
            var linkOutcomes = 0
            var linkFragmentCues = 0

            let refresh = Task { @MainActor in
                await RemoteMarkdownTabRefresh.refresh(
                    identity: identity,
                    documentID: tabID,
                    in: sessionID,
                    associatedWith: nil,
                    sessionStore: store,
                    selectingTab: true,
                    announceOutcome: true,
                    coordinator: RemoteMarkdownRefreshCoordinator(),
                    progress: progress,
                    onAnnounceLoading: { refreshLoading += 1 },
                    onAnnounceOutcome: { _ in refreshOutcomes += 1 },
                    startAttempt: { reference in
                        preparedAttempt(consumer: .refresh, cohort: cohort) {
                            await gate.wait()
                            return .fresh(
                                RemoteMarkdownSnapshot(fileURL: cacheURL, identity: reference.identity))
                        }
                    }
                )
            }
            await gate.waitUntilStarted()

            _ = await RemoteMarkdownDocumentLinkNavigation.open(
                url: link,
                from: source,
                in: sessionID,
                associatedWith: nil,
                sessionStore: store,
                coordinator: RemoteMarkdownDocumentLinkCoordinator(),
                startAttempt: { reference in
                    preparedAttempt(
                        consumer: .document,
                        outcome: .fresh(
                            RemoteMarkdownSnapshot(fileURL: cacheURL, identity: reference.identity)),
                        cohort: cohort
                    )
                },
                onAnnounceLoading: { linkLoading += 1 },
                onAnnounceOutcome: { _ in linkOutcomes += 1 },
                onAnnounceFragmentOpened: { linkFragmentCues += 1 },
                progress: progress
            )
            gate.open()
            _ = await refresh.value

            #expect(refreshLoading == 1)
            #expect(refreshOutcomes == 0)
            #expect(linkLoading == 0)
            #expect(linkOutcomes == 1)
            #expect(linkFragmentCues == 0)
            #expect(!progress.isInFlight(sessionID: sessionID, identity: identity))
        case "linkThenRefreshSharesAnnouncementOwnership":
            let identity = remoteIdentity()
            let source = remoteIdentity(path: "/repo/README.md")
            let link = try #require(
                RemoteMarkdownReference.linkURL(forMarkdownDestination: "doc.md", relativeTo: source)
            )
            let cacheURL = URL(fileURLWithPath: "/tmp/awesomux-link-race-\(UUID().uuidString).md")
            let (store, sessionID, tabID) = try storeWithRemoteTab(identity: identity, cacheURL: cacheURL)
            _ = try #require(
                store.openDocumentPane(
                    fileURL: cacheURL, in: sessionID, remoteResourceIdentity: source,
                    associationPolicy: .preserveNil, selectingNewTab: false
                ))
            let progress = RemoteMarkdownFetchProgressCoordinator()
            let gate = FetchGate()
            let cohort = RemoteMarkdownFetchCoordinator.Cohort()
            cohort.add(.document)
            cohort.add(.refresh)
            var refreshLoading = 0
            var refreshOutcomes = 0
            var linkLoading = 0
            var linkOutcomes = 0

            let open = Task { @MainActor in
                await RemoteMarkdownDocumentLinkNavigation.open(
                    url: link,
                    from: source,
                    in: sessionID,
                    associatedWith: nil,
                    sessionStore: store,
                    coordinator: RemoteMarkdownDocumentLinkCoordinator(),
                    startAttempt: { reference in
                        preparedAttempt(consumer: .document, cohort: cohort) {
                            await gate.wait()
                            return .fresh(
                                RemoteMarkdownSnapshot(fileURL: cacheURL, identity: reference.identity))
                        }
                    },
                    onAnnounceLoading: { linkLoading += 1 },
                    onAnnounceOutcome: { _ in linkOutcomes += 1 },
                    progress: progress
                )
            }
            await gate.waitUntilStarted()

            _ = await RemoteMarkdownTabRefresh.refresh(
                identity: identity,
                documentID: tabID,
                in: sessionID,
                associatedWith: nil,
                sessionStore: store,
                selectingTab: true,
                announceOutcome: true,
                coordinator: RemoteMarkdownRefreshCoordinator(),
                progress: progress,
                onAnnounceLoading: { refreshLoading += 1 },
                onAnnounceOutcome: { _ in refreshOutcomes += 1 },
                startAttempt: { reference in
                    preparedAttempt(
                        consumer: .refresh,
                        outcome: .fresh(
                            RemoteMarkdownSnapshot(fileURL: cacheURL, identity: reference.identity)),
                        cohort: cohort
                    )
                }
            )
            gate.open()
            _ = await open.value

            #expect(linkLoading == 1)
            #expect(linkOutcomes == 0)
            #expect(refreshLoading == 0)
            #expect(refreshOutcomes == 1)
        case "sameFileNilFetchKeepsLinkFailureAfterTabCloses":
            let identity = remoteIdentity()
            let source = remoteIdentity(path: "/repo/README.md")
            let link = try #require(
                RemoteMarkdownReference.linkURL(forMarkdownDestination: "doc.md", relativeTo: source)
            )
            let cacheURL = URL(fileURLWithPath: "/tmp/awesomux-failure-race-\(UUID().uuidString).md")
            let (store, sessionID, tabID) = try storeWithRemoteTab(identity: identity, cacheURL: cacheURL)
            _ = try #require(
                store.openDocumentPane(
                    fileURL: cacheURL, in: sessionID, remoteResourceIdentity: source,
                    associationPolicy: .preserveNil, selectingNewTab: false
                ))
            let progress = RemoteMarkdownFetchProgressCoordinator()
            let cohort = RemoteMarkdownFetchCoordinator.Cohort()
            cohort.add(.refresh)
            cohort.add(.document)
            let gate = FetchGate()
            var refreshFailures = 0
            var linkFailures = 0

            let refresh = Task { @MainActor in
                await RemoteMarkdownTabRefresh.refresh(
                    identity: identity,
                    documentID: tabID,
                    in: sessionID,
                    associatedWith: nil,
                    sessionStore: store,
                    selectingTab: true,
                    announceOutcome: true,
                    progress: progress,
                    onAnnounceLoading: {},
                    onAnnounceFailure: { refreshFailures += 1 },
                    startAttempt: { _ in
                        preparedAttempt(consumer: .refresh, cohort: cohort) {
                            await gate.wait()
                            return nil
                        }
                    }
                )
            }
            await gate.waitUntilStarted()
            _ = await RemoteMarkdownDocumentLinkNavigation.open(
                url: link,
                from: source,
                in: sessionID,
                associatedWith: nil,
                sessionStore: store,
                coordinator: RemoteMarkdownDocumentLinkCoordinator(),
                startAttempt: { _ in preparedAttempt(consumer: .document, outcome: nil, cohort: cohort) },
                onFetchFailure: { linkFailures += 1 },
                onAnnounceLoading: {},
                progress: progress
            )
            store.closeDocumentPane(documentID: tabID, in: sessionID)
            gate.open()
            _ = await refresh.value

            #expect(refreshFailures == 0)
            #expect(linkFailures == 1)
        case "cancelledRefreshDefersNilFailureToSameFileLink":
            let identity = remoteIdentity()
            let source = remoteIdentity(path: "/repo/README.md")
            let link = try #require(
                RemoteMarkdownReference.linkURL(forMarkdownDestination: "doc.md", relativeTo: source)
            )
            let cacheURL = URL(fileURLWithPath: "/tmp/awesomux-cancelled-failure-\(UUID().uuidString).md")
            let (store, sessionID, tabID) = try storeWithRemoteTab(identity: identity, cacheURL: cacheURL)
            _ = try #require(
                store.openDocumentPane(
                    fileURL: cacheURL, in: sessionID, remoteResourceIdentity: source,
                    associationPolicy: .preserveNil, selectingNewTab: false
                ))
            let progress = RemoteMarkdownFetchProgressCoordinator()
            let cohort = RemoteMarkdownFetchCoordinator.Cohort()
            cohort.add(.refresh)
            cohort.add(.document)
            let gate = FetchGate()
            var refreshFailures = 0
            var linkFailures = 0

            let refresh = Task { @MainActor in
                await RemoteMarkdownTabRefresh.refresh(
                    identity: identity,
                    documentID: tabID,
                    in: sessionID,
                    associatedWith: nil,
                    sessionStore: store,
                    selectingTab: true,
                    announceOutcome: true,
                    progress: progress,
                    onAnnounceLoading: {},
                    onAnnounceFailure: { refreshFailures += 1 },
                    startAttempt: { _ in
                        preparedAttempt(consumer: .refresh, cohort: cohort) {
                            await gate.wait()
                            return nil
                        }
                    }
                )
            }
            await gate.waitUntilStarted()
            _ = await RemoteMarkdownDocumentLinkNavigation.open(
                url: link,
                from: source,
                in: sessionID,
                associatedWith: nil,
                sessionStore: store,
                coordinator: RemoteMarkdownDocumentLinkCoordinator(),
                startAttempt: { _ in preparedAttempt(consumer: .document, outcome: nil, cohort: cohort) },
                onFetchFailure: { linkFailures += 1 },
                onAnnounceLoading: {},
                progress: progress
            )
            refresh.cancel()
            gate.open()
            _ = await refresh.value

            #expect(refreshFailures == 0)
            #expect(linkFailures == 1)
        case "restoreDefersFailureToSameFileLink":
            let identity = remoteIdentity()
            let source = remoteIdentity(path: "/repo/README.md")
            let link = try #require(
                RemoteMarkdownReference.linkURL(forMarkdownDestination: "doc.md", relativeTo: source)
            )
            let cacheURL = URL(fileURLWithPath: "/tmp/awesomux-restore-link-failure-\(UUID().uuidString).md")
            let (store, sessionID, tabID) = try storeWithRemoteTab(identity: identity, cacheURL: cacheURL)
            _ = try #require(
                store.openDocumentPane(
                    fileURL: cacheURL, in: sessionID, remoteResourceIdentity: source,
                    associationPolicy: .preserveNil, selectingNewTab: false
                ))
            let progress = RemoteMarkdownFetchProgressCoordinator()
            let cohort = RemoteMarkdownFetchCoordinator.Cohort()
            cohort.add(.restore)
            cohort.add(.document)
            let gate = FetchGate()
            var restoreFailures = 0
            var linkFailures = 0

            let restore = Task { @MainActor in
                await RemoteMarkdownTabRefresh.refresh(
                    identity: identity,
                    documentID: tabID,
                    in: sessionID,
                    associatedWith: nil,
                    sessionStore: store,
                    selectingTab: false,
                    announceFailure: true,
                    progress: progress,
                    onAnnounceFailure: { restoreFailures += 1 },
                    startAttempt: { _ in
                        preparedAttempt(consumer: .restore, cohort: cohort) {
                            await gate.wait()
                            return nil
                        }
                    }
                )
            }
            await gate.waitUntilStarted()
            _ = await RemoteMarkdownDocumentLinkNavigation.open(
                url: link,
                from: source,
                in: sessionID,
                associatedWith: nil,
                sessionStore: store,
                coordinator: RemoteMarkdownDocumentLinkCoordinator(),
                startAttempt: { _ in preparedAttempt(consumer: .document, outcome: nil, cohort: cohort) },
                onFetchFailure: { linkFailures += 1 },
                onAnnounceLoading: {},
                progress: progress
            )
            gate.open()
            _ = await restore.value

            #expect(restoreFailures == 0)
            #expect(linkFailures == 1)
        case "restoreUsesFetchCohortInsteadOfHistoricalDocumentProgress":
            let identity = remoteIdentity()
            let cacheURL = URL(fileURLWithPath: "/tmp/awesomux-restore-next-cohort-\(UUID().uuidString).md")
            let (store, sessionID, tabID) = try storeWithRemoteTab(identity: identity, cacheURL: cacheURL)
            let progress = RemoteMarkdownFetchProgressCoordinator()
            _ = progress.begin(sessionID: sessionID, identity: identity, origin: .document)
            let restoreCohort = RemoteMarkdownFetchCoordinator.Cohort()
            restoreCohort.add(.restore)
            var restoreFailures = 0

            _ = await RemoteMarkdownTabRefresh.refresh(
                identity: identity,
                documentID: tabID,
                in: sessionID,
                associatedWith: nil,
                sessionStore: store,
                selectingTab: false,
                announceFailure: true,
                progress: progress,
                onAnnounceFailure: { restoreFailures += 1 },
                startAttempt: { _ in preparedAttempt(consumer: .restore, outcome: nil, cohort: restoreCohort) }
            )
            progress.finish(sessionID: sessionID, identity: identity, origin: .document)

            #expect(restoreFailures == 1)
        case "refreshDefersNilToFailurePresenter":
            let identity = remoteIdentity()
            let cacheURL = URL(fileURLWithPath: "/tmp/awesomux-refresh-presenter-\(UUID().uuidString).md")
            let (store, sessionID, tabID) = try storeWithRemoteTab(identity: identity, cacheURL: cacheURL)
            let cohort = RemoteMarkdownFetchCoordinator.Cohort()
            _ = cohort.register(.failurePresenter, sessionID: sessionID)
            var failures = 0

            _ = await RemoteMarkdownTabRefresh.refresh(
                identity: identity,
                documentID: tabID,
                in: sessionID,
                associatedWith: nil,
                sessionStore: store,
                selectingTab: true,
                announceOutcome: true,
                onAnnounceLoading: {},
                onAnnounceFailure: { failures += 1 },
                startAttempt: { _ in
                    preparedAttempt(
                        consumer: .refresh,
                        outcome: nil,
                        cohort: cohort,
                        announcementSessionID: sessionID
                    )
                }
            )

            #expect(failures == 1)
            #expect(!cohort.claimOutcome(sessionID: sessionID))
        case "restoreFailureOwnershipIsSessionScoped":
            let identity = remoteIdentity()
            let cacheURL = URL(fileURLWithPath: "/tmp/awesomux-restore-session-scope-\(UUID().uuidString).md")
            let (store, sessionID, tabID) = try storeWithRemoteTab(identity: identity, cacheURL: cacheURL)
            let cohort = RemoteMarkdownFetchCoordinator.Cohort()
            _ = cohort.register(.failurePresenter, sessionID: UUID())
            var failures = 0

            _ = await RemoteMarkdownTabRefresh.refresh(
                identity: identity,
                documentID: tabID,
                in: sessionID,
                associatedWith: nil,
                sessionStore: store,
                selectingTab: false,
                announceFailure: true,
                onAnnounceFailure: { failures += 1 },
                startAttempt: { _ in
                    preparedAttempt(
                        consumer: .restore,
                        outcome: nil,
                        cohort: cohort,
                        announcementSessionID: sessionID
                    )
                }
            )

            #expect(failures == 1)
        case "laterRefreshCohortOwnsSuccess":
            let identity = remoteIdentity()
            let cacheURL = URL(fileURLWithPath: "/tmp/awesomux-refresh-next-success-\(UUID().uuidString).md")
            let (store, sessionID, tabID) = try storeWithRemoteTab(identity: identity, cacheURL: cacheURL)
            let progress = RemoteMarkdownFetchProgressCoordinator()
            _ = progress.begin(
                sessionID: sessionID,
                identity: identity,
                origin: .document
            )
            let refreshCohort = RemoteMarkdownFetchCoordinator.Cohort()
            refreshCohort.add(.refresh)
            var loading = 0
            var outcomes = 0

            _ = await RemoteMarkdownTabRefresh.refresh(
                identity: identity,
                documentID: tabID,
                in: sessionID,
                associatedWith: nil,
                sessionStore: store,
                selectingTab: true,
                announceOutcome: true,
                progress: progress,
                onAnnounceLoading: { loading += 1 },
                onAnnounceOutcome: { _ in outcomes += 1 },
                startAttempt: { reference in
                    preparedAttempt(
                        consumer: .refresh,
                        outcome: .fresh(
                            RemoteMarkdownSnapshot(fileURL: cacheURL, identity: reference.identity)),
                        cohort: refreshCohort
                    )
                }
            )

            #expect(loading == 1)
            #expect(outcomes == 1)
        case "laterRefreshCohortOwnsFailure":
            let identity = remoteIdentity()
            let cacheURL = URL(fileURLWithPath: "/tmp/awesomux-refresh-next-failure-\(UUID().uuidString).md")
            let (store, sessionID, tabID) = try storeWithRemoteTab(identity: identity, cacheURL: cacheURL)
            let progress = RemoteMarkdownFetchProgressCoordinator()
            _ = progress.begin(
                sessionID: sessionID,
                identity: identity,
                origin: .document
            )
            let refreshCohort = RemoteMarkdownFetchCoordinator.Cohort()
            refreshCohort.add(.refresh)
            var loading = 0
            var failures = 0

            _ = await RemoteMarkdownTabRefresh.refresh(
                identity: identity,
                documentID: tabID,
                in: sessionID,
                associatedWith: nil,
                sessionStore: store,
                selectingTab: true,
                announceOutcome: true,
                progress: progress,
                onAnnounceLoading: { loading += 1 },
                onAnnounceFailure: { failures += 1 },
                startAttempt: { _ in preparedAttempt(consumer: .refresh, outcome: nil, cohort: refreshCohort) }
            )

            #expect(loading == 1)
            #expect(failures == 1)
        case "restoreKeepsSameCohortDocumentPresentationOwnership":
            let identity = remoteIdentity()
            let cacheURL = URL(fileURLWithPath: "/tmp/awesomux-restore-same-cohort-\(UUID().uuidString).md")
            let (store, sessionID, tabID) = try storeWithRemoteTab(identity: identity, cacheURL: cacheURL)
            let progress = RemoteMarkdownFetchProgressCoordinator()
            _ = progress.begin(sessionID: sessionID, identity: identity, origin: .document)
            let sharedCohort = RemoteMarkdownFetchCoordinator.Cohort()
            sharedCohort.add(.document)
            sharedCohort.add(.restore)
            progress.finish(sessionID: sessionID, identity: identity, origin: .document)
            var restoreFailures = 0

            _ = await RemoteMarkdownTabRefresh.refresh(
                identity: identity,
                documentID: tabID,
                in: sessionID,
                associatedWith: nil,
                sessionStore: store,
                selectingTab: false,
                announceFailure: true,
                progress: progress,
                onAnnounceFailure: { restoreFailures += 1 },
                startAttempt: { _ in preparedAttempt(consumer: .restore, outcome: nil, cohort: sharedCohort) }
            )

            #expect(restoreFailures == 0)
        case "restoreDoesNotTakeSameFileLinkSuccessCues":
            let identity = remoteIdentity()
            let source = remoteIdentity(path: "/repo/README.md")
            let link = try #require(
                RemoteMarkdownReference.linkURL(forMarkdownDestination: "doc.md", relativeTo: source)
            )
            let cacheURL = URL(fileURLWithPath: "/tmp/awesomux-restore-link-success-\(UUID().uuidString).md")
            let (store, sessionID, tabID) = try storeWithRemoteTab(identity: identity, cacheURL: cacheURL)
            _ = try #require(
                store.openDocumentPane(
                    fileURL: cacheURL, in: sessionID, remoteResourceIdentity: source,
                    associationPolicy: .preserveNil, selectingNewTab: false
                ))
            let progress = RemoteMarkdownFetchProgressCoordinator()
            let gate = FetchGate()
            let cohort = RemoteMarkdownFetchCoordinator.Cohort()
            cohort.add(.refresh)
            cohort.add(.document)
            var linkLoading = 0
            var linkOutcomes = 0

            let restore = Task { @MainActor in
                await RemoteMarkdownTabRefresh.refresh(
                    identity: identity,
                    documentID: tabID,
                    in: sessionID,
                    associatedWith: nil,
                    sessionStore: store,
                    selectingTab: false,
                    announceFailure: true,
                    progress: progress,
                    startAttempt: { reference in
                        preparedAttempt(consumer: .restore, cohort: cohort) {
                            await gate.wait()
                            return .fresh(
                                RemoteMarkdownSnapshot(fileURL: cacheURL, identity: reference.identity))
                        }
                    }
                )
            }
            await gate.waitUntilStarted()
            _ = await RemoteMarkdownDocumentLinkNavigation.open(
                url: link,
                from: source,
                in: sessionID,
                associatedWith: nil,
                sessionStore: store,
                coordinator: RemoteMarkdownDocumentLinkCoordinator(),
                startAttempt: { reference in
                    preparedAttempt(
                        consumer: .document,
                        outcome: .fresh(
                            RemoteMarkdownSnapshot(fileURL: cacheURL, identity: reference.identity)),
                        cohort: cohort
                    )
                },
                onAnnounceLoading: { linkLoading += 1 },
                onAnnounceOutcome: { _ in linkOutcomes += 1 },
                progress: progress
            )
            gate.open()
            _ = await restore.value

            #expect(linkLoading == 1)
            #expect(linkOutcomes == 1)
        case "cancelledRefreshReleasesAnnouncementOwnership":
            let identity = remoteIdentity()
            let source = remoteIdentity(path: "/repo/README.md")
            let link = try #require(
                RemoteMarkdownReference.linkURL(forMarkdownDestination: "doc.md", relativeTo: source)
            )
            let cacheURL = URL(fileURLWithPath: "/tmp/awesomux-cancel-race-\(UUID().uuidString).md")
            let (store, sessionID, tabID) = try storeWithRemoteTab(identity: identity, cacheURL: cacheURL)
            _ = try #require(
                store.openDocumentPane(
                    fileURL: cacheURL, in: sessionID, remoteResourceIdentity: source,
                    associationPolicy: .preserveNil, selectingNewTab: false
                ))
            let progress = RemoteMarkdownFetchProgressCoordinator()
            let gate = FetchGate()
            let cohort = RemoteMarkdownFetchCoordinator.Cohort()
            cohort.add(.refresh)
            cohort.add(.document)
            var refreshOutcomes = 0
            var linkLoading = 0
            var linkOutcomes = 0

            let refresh = Task { @MainActor in
                await RemoteMarkdownTabRefresh.refresh(
                    identity: identity,
                    documentID: tabID,
                    in: sessionID,
                    associatedWith: nil,
                    sessionStore: store,
                    selectingTab: true,
                    announceOutcome: true,
                    progress: progress,
                    onAnnounceLoading: {},
                    onAnnounceOutcome: { _ in refreshOutcomes += 1 },
                    startAttempt: { reference in
                        preparedAttempt(consumer: .refresh, cohort: cohort) {
                            await gate.wait()
                            return .fresh(
                                RemoteMarkdownSnapshot(fileURL: cacheURL, identity: reference.identity))
                        }
                    }
                )
            }
            await gate.waitUntilStarted()

            _ = await RemoteMarkdownDocumentLinkNavigation.open(
                url: link,
                from: source,
                in: sessionID,
                associatedWith: nil,
                sessionStore: store,
                coordinator: RemoteMarkdownDocumentLinkCoordinator(),
                startAttempt: { reference in
                    preparedAttempt(
                        consumer: .document,
                        outcome: .fresh(
                            RemoteMarkdownSnapshot(fileURL: cacheURL, identity: reference.identity)),
                        cohort: cohort
                    )
                },
                onAnnounceLoading: { linkLoading += 1 },
                onAnnounceOutcome: { _ in linkOutcomes += 1 },
                progress: progress
            )
            refresh.cancel()
            gate.open()
            _ = await refresh.value

            #expect(refreshOutcomes == 0)
            #expect(linkLoading == 0)
            #expect(linkOutcomes == 1)
        default: Issue.record("Unknown scenario: \(scenario)")
        }
    }

}

private func preparedAttempt(
    consumer: RemoteMarkdownFetchCoordinator.Cohort.Consumer,
    outcome: RemoteMarkdownFetchOutcome?,
    cohort: RemoteMarkdownFetchCoordinator.Cohort,
    announcementSessionID: UUID? = nil
) -> RemoteMarkdownFetchCoordinator.PreparedAttempt {
    preparedAttempt(
        consumer: consumer,
        cohort: cohort,
        announcementSessionID: announcementSessionID
    ) { outcome }
}

private func preparedAttempt(
    consumer: RemoteMarkdownFetchCoordinator.Cohort.Consumer,
    cohort: RemoteMarkdownFetchCoordinator.Cohort,
    announcementSessionID: UUID? = nil,
    operation: @escaping @Sendable () async -> RemoteMarkdownFetchOutcome?
) -> RemoteMarkdownFetchCoordinator.PreparedAttempt {
    .init(
        cohort: cohort,
        announcementSessionID: announcementSessionID,
        ownsAnnouncements: cohort.register(consumer, sessionID: announcementSessionID),
        task: Task { await operation() },
        isNew: true,
        onCoalesced: nil,
        onRegistered: nil
    )
}
