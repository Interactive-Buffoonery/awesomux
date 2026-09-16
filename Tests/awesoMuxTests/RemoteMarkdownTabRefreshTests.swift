import AwesoMuxCore
import Foundation
import Testing

@testable import awesoMux

@MainActor
@Suite("Remote Markdown tab refresh")
struct RemoteMarkdownTabRefreshTests {
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

    private let refreshFailedMessage =
        "Remote Markdown refresh failed. Showing the saved cached copy, which may be stale."

    /// Captures announcer output and can await one specific message, so a test
    /// can assert on the fire-and-forget restore sweep deterministically. The
    /// announcer poster is global and parallel suites post through it, so
    /// assertions count the sentence under test rather than the whole log.
    private final class AnnouncementProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var messages: [String] = []
        private var expected: String?
        private var waiter: CheckedContinuation<Void, Never>?

        func record(_ message: String) {
            lock.lock()
            messages.append(message)
            let resume = expected.map { messages.contains($0) } ?? false
            let waiter = resume ? self.waiter : nil
            if resume { self.waiter = nil }
            lock.unlock()
            waiter?.resume()
        }

        /// Resumes once `message` has been recorded, or immediately if it
        /// already has been.
        func waitFor(_ message: String) async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if messages.contains(message) {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                expected = message
                waiter = continuation
                lock.unlock()
            }
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

    @Test("refresh applies a successful fetch to the open tab")
    func refreshAppliesSuccessfulFetch() async throws {
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

        RemoteMarkdownTabRefresh.scheduleRestoreRefresh(for: store) { reference in
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

        #expect(Set(box.snapshot) == Set([identityA, identityB]))
        #expect(RemoteSnapshotStalePolicy.bannerKind(path: pathA) == .remoteStoppedRefreshing)
        #expect(RemoteSnapshotStalePolicy.bannerKind(path: pathB) == .remoteStoppedRefreshing)
    }

    @Test("scheduleRestoreRefresh bounds concurrent fetches")
    func scheduleRestoreRefreshBoundsConcurrency() async throws {
        let tabCount = 8
        var identities: [ResourceIdentity] = []
        var cachePaths: [String] = []
        defer {
            for path in cachePaths {
                RemoteSnapshotStalePolicy.note(nil, path: path)
            }
        }

        let store = SessionStore()
        let sessionID = store.addSession(workingDirectory: "/tmp")
        let session = try #require(store.session(id: sessionID))
        let terminalID = session.activePaneID
        // Distinct hosts so the fetch coordinator's per-target serialization
        // never masks the restore fan-out bound under test.
        for index in 0..<tabCount {
            let identity = ResourceIdentity(
                location: .remote(RemoteTarget(parsing: "host-\(index)")!),
                path: ResourcePath(rawValue: "/repo/doc.md")
            )
            identities.append(identity)
            let path = "/tmp/awesomux-restore-bound-\(index)-\(UUID().uuidString).md"
            cachePaths.append(path)
            _ = store.openDocumentPane(
                fileURL: URL(fileURLWithPath: path),
                in: sessionID,
                associatedWith: terminalID,
                remoteResourceIdentity: identity
            )
        }
        let cachePathByIdentity = Dictionary(uniqueKeysWithValues: zip(identities, cachePaths))

        final class ConcurrencyBox: @unchecked Sendable {
            private let lock = NSLock()
            private var inFlight = 0
            private var maxInFlight = 0
            private var started = 0
            private var waiters: [CheckedContinuation<Void, Never>] = []

            func enter(total: Int) {
                lock.lock()
                inFlight += 1
                maxInFlight = max(maxInFlight, inFlight)
                started += 1
                let done = started >= total
                let waiters = done ? self.waiters : []
                if done { self.waiters = [] }
                lock.unlock()
                for waiter in waiters {
                    waiter.resume()
                }
            }

            func leave() {
                lock.lock()
                inFlight -= 1
                lock.unlock()
            }

            var maxObserved: Int {
                lock.lock()
                defer { lock.unlock() }
                return maxInFlight
            }

            func waitUntilStarted(_ total: Int) async {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    lock.lock()
                    if started >= total {
                        lock.unlock()
                        continuation.resume()
                        return
                    }
                    waiters.append(continuation)
                    lock.unlock()
                }
            }
        }
        let box = ConcurrencyBox()

        RemoteMarkdownTabRefresh.scheduleRestoreRefresh(for: store) { reference in
            box.enter(total: tabCount)
            try? await Task.sleep(for: .milliseconds(20))
            box.leave()
            return .fresh(
                RemoteMarkdownSnapshot(
                    fileURL: URL(
                        fileURLWithPath: cachePathByIdentity[reference.identity]
                            ?? "/tmp/awesomux-restore-bound-fallback.md"),
                    identity: reference.identity
                )
            )
        }

        await box.waitUntilStarted(tabCount)

        #expect(box.maxObserved <= 4)
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

    @Test("refresh speaks the unavailable outcome when announceFailure is set")
    func refreshAnnouncesFailureWhenRequested() async throws {
        let identity = remoteIdentity()
        let path = "/tmp/awesomux-refresh-announce-\(UUID().uuidString).md"
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
            announceOutcome: false,
            announceFailure: true,
            fetch: { _ in nil }
        )

        await probe.waitFor(refreshFailedMessage)
        #expect(probe.count(of: refreshFailedMessage) == 1)
    }

    @Test("refresh stays silent on failure when neither announce flag is set")
    func refreshFailureSilentWithoutFlags() async throws {
        let identity = remoteIdentity()
        let path = "/tmp/awesomux-refresh-quiet-\(UUID().uuidString).md"
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
            announceOutcome: false,
            announceFailure: false,
            fetch: { _ in nil }
        )

        #expect(probe.count(of: refreshFailedMessage) == 0)
        #expect(RemoteSnapshotStalePolicy.bannerKind(path: path) == .remoteRefreshFailed)
    }

    @Test("refresh does not speak success when only announceFailure is set")
    func refreshSuccessSilentForFailureOnlyAnnounce() async throws {
        let identity = remoteIdentity()
        let path = "/tmp/awesomux-refresh-success-quiet-\(UUID().uuidString).md"
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
            announceOutcome: false,
            announceFailure: true,
            fetch: { reference in
                .fresh(
                    RemoteMarkdownSnapshot(
                        fileURL: URL(fileURLWithPath: path),
                        identity: reference.identity
                    )
                )
            }
        )

        #expect(probe.count(of: refreshFailedMessage) == 0)
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

    @Test("restore speaks a refresh failure for the selected tab")
    func restoreAnnouncesFailureForSelectedTab() async throws {
        let identity = remoteIdentity()
        let path = "/tmp/awesomux-restore-announce-\(UUID().uuidString).md"
        defer { RemoteSnapshotStalePolicy.note(nil, path: path) }
        let (store, _, _) = try storeWithRemoteTab(
            identity: identity,
            cacheURL: URL(fileURLWithPath: path)
        )

        let probe = AnnouncementProbe()
        let previous = TerminalAccessibilityAnnouncer.announcementPoster
        TerminalAccessibilityAnnouncer.setAnnouncementPosterForTesting { message, _ in
            probe.record(message)
        }
        defer { TerminalAccessibilityAnnouncer.setAnnouncementPosterForTesting(previous) }

        RemoteMarkdownTabRefresh.scheduleRestoreRefresh(for: store) { _ in nil }

        await probe.waitFor(refreshFailedMessage)
        #expect(probe.count(of: refreshFailedMessage) == 1)
    }
}

@Suite("Remote Markdown tab refresh localization catalog coverage")
struct RemoteMarkdownTabRefreshCatalogTests {
    @Test func remoteRefreshAffordanceLiteralsAreCatalogKeys() throws {
        let keys = try AwesoMuxStringCatalog.keys()
        for literal in [
            "re-fetches this remote Markdown file over SSH",
            "re-fetching remote Markdown",
            "Refresh",
            "Read-only snapshot from %arg",
            "Read-only remote Markdown snapshot from %arg",
            // Nil-fetch VoiceOver path reuses the announcer's cached-failure
            // sentence — pin the catalog key here so a drift that reintroduces
            // a duplicate localized literal in TabRefresh is visible.
            "Remote Markdown refresh failed. Showing the saved cached copy, which may be stale.",
        ] {
            #expect(keys.contains(literal), "Localizable.xcstrings has no key \"\(literal)\"")
        }
    }

    @Test("nil-fetch VoiceOver goes through the shared announcer, not a duplicate literal")
    func nilFetchAnnouncementReusesAnnouncer() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appending(
                path: "Sources/awesoMux/Services/RemoteMarkdownTabRefresh.swift"),
            encoding: .utf8
        )
        #expect(source.contains("announceRemoteMarkdownRefreshUnavailable()"))
        #expect(
            !source.contains(
                "Remote Markdown refresh failed. Showing the saved cached copy, which may be stale."),
            "TabRefresh must not re-own the cached-failure VoiceOver literal"
        )
    }
}
