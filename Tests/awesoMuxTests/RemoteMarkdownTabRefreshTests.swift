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

    @Test("restore targets collect every remote Markdown tab and skip local docs")
    func restoreTargetsCollectRemoteTabsOnly() throws {
        let store = SessionStore()
        let sessionID = store.addSession(workingDirectory: "/tmp")
        let session = try #require(store.session(id: sessionID))
        let terminalID = session.activePaneID
        let remoteIdentity = remoteIdentity()
        let cacheURL = URL(fileURLWithPath: "/tmp/remote-cache-\(UUID().uuidString).md")
        _ = store.openDocumentPane(
            fileURL: cacheURL,
            in: sessionID,
            associatedWith: terminalID,
            remoteResourceIdentity: remoteIdentity
        )
        _ = store.openDocumentPane(
            fileURL: URL(fileURLWithPath: "/tmp/local-\(UUID().uuidString).md"),
            in: sessionID,
            associatedWith: terminalID
        )

        let targets = RemoteMarkdownTabRefresh.restoreTargets(in: store)

        #expect(targets.count == 1)
        #expect(targets[0].sessionID == sessionID)
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
        // Select A, then apply a refresh for B without selecting.
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
        ] {
            #expect(keys.contains(literal), "Localizable.xcstrings has no key \"\(literal)\"")
        }
    }
}
