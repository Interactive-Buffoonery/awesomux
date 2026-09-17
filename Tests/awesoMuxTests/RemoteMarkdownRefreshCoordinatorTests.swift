import AwesoMuxCore
import AwesoMuxTestSupport
import Foundation
import Testing

@testable import awesoMux

@Suite("Remote Markdown refresh coordinator")
@MainActor
struct RemoteMarkdownRefreshCoordinatorTests {
    @Test("begin marks the document as refreshing")
    func beginMarksTheDocument() {
        let coordinator = RemoteMarkdownRefreshCoordinator()
        let documentID = UUID()
        #expect(!coordinator.isRefreshing(documentID))
        #expect(coordinator.begin(documentID: documentID))
        #expect(coordinator.isRefreshing(documentID))
    }

    @Test("finish clears the document")
    func finishClearsTheDocument() {
        let coordinator = RemoteMarkdownRefreshCoordinator()
        let documentID = UUID()
        #expect(coordinator.begin(documentID: documentID))
        coordinator.finish(documentID: documentID)
        #expect(!coordinator.isRefreshing(documentID))
    }

    @Test("a second begin for the same document fails while the first is in flight")
    func secondBeginFailsWhileInFlight() {
        let coordinator = RemoteMarkdownRefreshCoordinator()
        let documentID = UUID()
        #expect(coordinator.begin(documentID: documentID))
        #expect(!coordinator.begin(documentID: documentID))
        #expect(coordinator.isRefreshing(documentID))
        coordinator.finish(documentID: documentID)
        #expect(coordinator.begin(documentID: documentID))
    }

    @Test("begin for a different document succeeds while another is refreshing")
    func differentDocumentsDoNotBlockEachOther() {
        let coordinator = RemoteMarkdownRefreshCoordinator()
        let first = UUID()
        let second = UUID()
        #expect(coordinator.begin(documentID: first))
        #expect(coordinator.begin(documentID: second))
        #expect(coordinator.isRefreshing(first))
        #expect(coordinator.isRefreshing(second))
    }
}

@Suite("Remote Markdown refresh coordinator gating")
@MainActor
struct RemoteMarkdownRefreshCoordinatorGateTests {
    private func remoteIdentity(path: String = "/repo/doc.md") -> ResourceIdentity {
        ResourceIdentity(
            location: .remote(RemoteTarget(parsing: "devbox")!),
            path: ResourcePath(rawValue: path)
        )
    }

    @Test("a second refresh for the same tab is refused without calling fetch")
    func secondRefreshIsRefusedWithoutFetch() async throws {
        let identity = remoteIdentity()
        let path = "/tmp/awesomux-refresh-gate-\(UUID().uuidString).md"
        defer { RemoteSnapshotStalePolicy.note(nil, path: path) }

        let store = SessionStore()
        let sessionID = store.addSession(workingDirectory: "/tmp")
        let session = try #require(store.session(id: sessionID))
        let tabID = try #require(
            store.openDocumentPane(
                fileURL: URL(fileURLWithPath: path),
                in: sessionID,
                associatedWith: session.activePaneID,
                remoteResourceIdentity: identity
            ))

        let coordinator = RemoteMarkdownRefreshCoordinator()
        #expect(coordinator.begin(documentID: tabID))

        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var _count = 0
            var count: Int {
                lock.lock()
                defer { lock.unlock() }
                return _count
            }
            func increment() {
                lock.lock()
                _count += 1
                lock.unlock()
            }
        }
        let fetchCalls = Box()

        let outcome = await RemoteMarkdownTabRefresh.refresh(
            identity: identity,
            documentID: tabID,
            in: sessionID,
            associatedWith: nil,
            sessionStore: store,
            selectingTab: true,
            announceOutcome: true,
            coordinator: coordinator,
            fetch: { _ in
                fetchCalls.increment()
                return .fresh(
                    RemoteMarkdownSnapshot(
                        fileURL: URL(fileURLWithPath: path),
                        identity: identity
                    )
                )
            }
        )

        #expect(outcome == nil)
        #expect(fetchCalls.count == 0)
        // The refused call must not clear the latch owned by the in-flight run.
        #expect(coordinator.isRefreshing(tabID))
        coordinator.finish(documentID: tabID)
    }

    @Test("refresh clears the coordinator latch after a successful apply")
    func refreshClearsLatchAfterApply() async throws {
        let identity = remoteIdentity()
        let path = "/tmp/awesomux-refresh-latch-\(UUID().uuidString).md"
        defer { RemoteSnapshotStalePolicy.note(nil, path: path) }

        let store = SessionStore()
        let sessionID = store.addSession(workingDirectory: "/tmp")
        let session = try #require(store.session(id: sessionID))
        let tabID = try #require(
            store.openDocumentPane(
                fileURL: URL(fileURLWithPath: path),
                in: sessionID,
                associatedWith: session.activePaneID,
                remoteResourceIdentity: identity
            ))

        let coordinator = RemoteMarkdownRefreshCoordinator()
        let outcome = await RemoteMarkdownTabRefresh.refresh(
            identity: identity,
            documentID: tabID,
            in: sessionID,
            associatedWith: nil,
            sessionStore: store,
            selectingTab: false,
            coordinator: coordinator,
            fetch: { _ in
                .fresh(
                    RemoteMarkdownSnapshot(
                        fileURL: URL(fileURLWithPath: path),
                        identity: identity
                    )
                )
            }
        )

        #expect(outcome != nil)
        #expect(!coordinator.isRefreshing(tabID))
    }
}

@Suite("DocumentPaneSendBar remote refresh busy-state wiring")
struct DocumentPaneSendBarRemoteRefreshBusyStateTests {
    private static let panePath = "Sources/awesoMux/Views/DocumentPaneView.swift"

    @Test("send bar busy state reads the durable coordinator, not only @State")
    func sendBarBusyStateReadsCoordinator() throws {
        let source = try SourceContract.source(at: Self.panePath)
        let sendBar = try SourceContract.declarationBody(
            after: "struct DocumentPaneSendBar: View {",
            in: source,
            path: Self.panePath
        )
        let busyState = try SourceContract.declarationBody(
            after: "private var isRemoteRefreshing: Bool {",
            in: source,
            path: Self.panePath
        )

        #expect(
            sendBar.contains("@Environment(RemoteMarkdownRefreshCoordinator.self)"),
            "DocumentPaneSendBar must read RemoteMarkdownRefreshCoordinator from the environment"
        )
        #expect(
            busyState.contains("remoteMarkdownRefreshCoordinator?.isRefreshing(pane.id)"),
            "Authoritative in-flight state must survive DocumentNudgeSendBarID remounts"
        )
    }
}
