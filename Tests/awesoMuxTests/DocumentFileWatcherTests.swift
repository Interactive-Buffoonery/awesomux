import AwesoMuxTestSupport
import Foundation
import Testing
@testable import awesoMux

// MARK: - DocumentFileWatcherTests

/// Exercises `DocumentFileWatcher`, with emphasis on the rename-replace re-arm path.
/// An atomic write (i.e. `String.write(to:atomically:encoding:)`) internally unlinks
/// the watched inode and substitutes a new one — the exact scenario that requires
/// re-arming the vnode source on the replacement fd.
///
/// The suite is @MainActor to give the test body a stable actor context matching
/// other async test suites in this target (e.g. RemoteConnectivityObserverTests).
@MainActor
@Suite("DocumentFileWatcher", .serialized)
struct DocumentFileWatcherTests {

    // MARK: - Helpers

    private func withTempFile(
        initialContent: String = "initial",
        body: (URL) async throws -> Void
    ) async throws {
        let temporaryDirectory = try TemporaryDirectory(prefix: "DocumentFileWatcherTests")
        let dir = temporaryDirectory.url
        defer { withExtendedLifetime(temporaryDirectory) {} }

        let url = dir.appendingPathComponent("test.md")
        try initialContent.write(to: url, atomically: false, encoding: .utf8)
        try await body(url)
    }

    // MARK: - Tests

    @Test("atomic and in-place writes notify the watcher", arguments: [true, false])
    func writesNotify(atomic: Bool) async throws {
        try await withTempFile { url in
            let counter = Counter()
            let watcher = DocumentFileWatcher(url: url) { counter.increment() }
            watcher.start()
            defer { watcher.stop() }
            try (atomic ? "new content" : "updated").write(to: url, atomically: atomic, encoding: .utf8)
            #expect(await waitUntilEventually(deadline: .seconds(10)) { counter.value > 0 })
        }
    }

    @Test("delayed recreation fires onChange after successful re-arm")
    func delayedRecreationFiresAfterRearm() async throws {
        try await withTempFile { url in
            let callbackFileStates = FileStateRecorder()
            let watcher = DocumentFileWatcher(url: url) {
                callbackFileStates.record(FileManager.default.fileExists(atPath: url.path))
            }
            watcher.start()

            try "first event".write(to: url, atomically: false, encoding: .utf8)
            try await Task.sleep(nanoseconds: 30_000_000)
            try FileManager.default.removeItem(at: url)
            let missingCallback = await waitUntilEventually(deadline: .seconds(10)) {
                callbackFileStates.values.contains(false)
            }
            try "recreated".write(to: url, atomically: false, encoding: .utf8)
            let rearmedCallback = await waitUntilEventually(deadline: .seconds(10)) {
                callbackFileStates.values.contains(true)
            }
            watcher.stop()

            #expect(missingCallback)
            #expect(rearmedCallback, "successful delayed re-arm should notify after the unreadable callback")
        }
    }

    @Test("delete without recreation notifies after retries are exhausted")
    func deleteWithoutRecreationNotifiesAfterExhaustion() async throws {
        try await withTempFile { url in
            let counter = Counter()
            let watcher = DocumentFileWatcher(url: url) { counter.increment() }
            watcher.start()

            try FileManager.default.removeItem(at: url)
            let received = await waitUntilEventually(deadline: .seconds(30)) { counter.value > 0 }
            watcher.stop()

            #expect(received, "retry exhaustion should notify so the pane can show its read error")
            #expect(counter.value == 1)
        }
    }

    /// `.leadingEdge` is the mode a file that a *process* appends to needs.
    ///
    /// Two properties at once, and the second is the one the default mode
    /// fails. Rate: a stream of writes far faster than the 100 ms window must
    /// not produce one callback per write. No starvation: the callbacks have to
    /// arrive *during* the stream, not after it stops — a trailing debounce
    /// restarts unconditionally, so its first delivery lands only once the
    /// writing has finished, which is precisely when a live transcript tab
    /// stops needing to update.
    @Test("coalescing .leadingEdge bounds the rate without waiting for the writing to stop")
    func leadingEdgeCoalescingBoundsTheRate() async throws {
        try await withTempFile { url in
            let counter = Counter()

            let watcher = DocumentFileWatcher(url: url, coalescing: .leadingEdge) {
                counter.increment()
            }
            watcher.start()

            // ~15 writes across ~450 ms: far more than the ~5 windows that fit.
            var deliveredDuringTheStream = 0
            for i in 0..<15 {
                try "content \(i)".write(to: url, atomically: false, encoding: .utf8)
                try await Task.sleep(nanoseconds: 30_000_000)  // 30 ms
                if i == 7 { deliveredDuringTheStream = counter.value }
            }
            let duringStream = deliveredDuringTheStream
            let delivered = await waitUntilEventually(deadline: .seconds(10)) { counter.value >= 2 }
            let total = counter.value
            watcher.stop()

            #expect(
                duringStream >= 1,
                "the leading edge must deliver while the writing is still going on"
            )
            #expect(delivered)
            #expect(
                total < 15,
                "a bounded rate must not degenerate into one callback per event"
            )
        }
    }

}

// MARK: - Thread-safe counter

/// A trivially thread-safe counter for tracking callback invocations in tests.
private final class Counter: Sendable {
    private nonisolated(unsafe) var _value = 0
    private let lock = DispatchQueue(label: "awesomux.test.counter")

    func increment() { lock.sync { _value += 1 } }
    var value: Int { lock.sync { _value } }
}

private final class FileStateRecorder: Sendable {
    private nonisolated(unsafe) var _values: [Bool] = []
    private let lock = DispatchQueue(label: "awesomux.test.file-state-recorder")

    func record(_ value: Bool) { lock.sync { _values.append(value) } }
    var values: [Bool] { lock.sync { _values } }
}
