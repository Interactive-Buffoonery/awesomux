import Foundation
import Testing
@testable import AwesoMuxConfig
@testable import awesoMux

@Suite("IDE priority drag lifecycle")
@MainActor
struct IDEReorderSessionTests {
    @Test func hoverCrossingsCommitOnlyAtEnd() {
        let session = IDEReorderSession()
        var commits: [[String]] = []
        let id = session.begin(bundleID: "a", order: ["a", "b", "c", "d"], priority: [])
        for target in ["b", "c", "d", "c", "b", "d"] {
            session.move(over: target)
            #expect(commits.isEmpty)
        }
        let visibleOrder = session.order
        #expect(visibleOrder != ["a", "b", "c", "d"])
        session.end(id: id, currentPriority: []) { commits.append($0) }
        #expect(commits.count == 1)
        #expect(commits.first == visibleOrder)
        #expect(session.order == nil)
        #expect(session.draggingBundleID == nil)
        session.end(id: id, currentPriority: []) { commits.append($0) }
        #expect(commits.count == 1)
    }

    @Test func gestureWritesConfigExactlyOnce() {
        let store = AppSettingsStore(
            fileStore: ConfigFileStore(
                configURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent(
                    "config.toml")),
            legacySnapshotProvider: { nil }
        )
        var writes = 0
        store.saveToDisk = { _ throws(ConfigFileStoreError) in writes += 1 }
        let session = IDEReorderSession()
        let priority = store.workspaces.value.defaultIDEPriority
        let id = session.begin(bundleID: "a", order: ["a", "b", "c"], priority: priority)
        session.move(over: "b")
        session.move(over: "c")
        #expect(writes == 0)
        session.end(id: id, currentPriority: store.workspaces.value.defaultIDEPriority) { order in
            store.workspaces.update { $0.defaultIDEPriority = order }
        }
        #expect(writes == 1)
        #expect(store.workspaces.value.defaultIDEPriority == ["b", "c", "a"])
        session.end(id: id, currentPriority: priority) { order in
            store.workspaces.update { $0.defaultIDEPriority = order }
        }
        #expect(writes == 1)
    }

    @Test func noReorderDoesNotCommit() {
        let session = IDEReorderSession()
        var count = 0
        let id = session.begin(bundleID: "a", order: ["a", "b"], priority: [])
        session.move(over: "a")
        session.move(over: "missing")
        session.end(id: id, currentPriority: []) { _ in count += 1 }
        #expect(count == 0)
        #expect(session.draggingBundleID == nil)
    }

    @Test func returnToOriginalOrderDoesNotCommit() {
        let session = IDEReorderSession()
        var count = 0
        let id = session.begin(bundleID: "a", order: ["a", "b"], priority: [])
        session.move(over: "b")
        session.move(over: "b")
        session.end(id: id, currentPriority: []) { _ in count += 1 }
        #expect(count == 0)
    }

    @Test func newerPriorityDiscardsDraft() {
        let session = IDEReorderSession()
        var count = 0
        let id = session.begin(bundleID: "a", order: ["a", "b", "c"], priority: [])
        session.move(over: "b")
        session.end(id: id, currentPriority: ["c", "b", "a"]) { _ in count += 1 }
        #expect(count == 0)
        #expect(session.draggingBundleID == nil)
    }

    @Test func teardownDiscardsPendingWrite() {
        let session = IDEReorderSession()
        var count = 0
        let id = session.begin(bundleID: "a", order: ["a", "b"], priority: [])
        session.move(over: "b")
        session.cancel()
        session.end(id: id, currentPriority: []) { _ in count += 1 }
        #expect(count == 0)
        #expect(session.order == nil)
        #expect(session.draggingBundleID == nil)
    }

    @Test func staleEndCannotFinishNewGesture() {
        let session = IDEReorderSession()
        var commits: [[String]] = []
        let oldID = session.begin(bundleID: "a", order: ["a", "b"], priority: [])
        session.move(over: "b")
        let newID = session.begin(bundleID: "b", order: ["a", "b"], priority: [])
        session.move(over: "a")
        session.end(id: oldID, currentPriority: []) { commits.append($0) }
        #expect(commits.isEmpty)
        #expect(session.draggingBundleID == "b")
        session.end(id: newID, currentPriority: []) { commits.append($0) }
        #expect(commits == [["b", "a"]])
    }

    @Test func clearsBeforeCallingCommit() {
        let session = IDEReorderSession()
        var count = 0
        let id = session.begin(bundleID: "a", order: ["a", "b"], priority: [])
        session.move(over: "b")
        session.end(id: id, currentPriority: []) { _ in
            count += 1
            #expect(session.order == nil)
            #expect(session.draggingBundleID == nil)
            session.end(id: id, currentPriority: []) { _ in count += 1 }
        }
        #expect(count == 1)
    }
}
