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

    /// An atomic write (rename-replace) fires `onChange`.
    ///
    /// This is the canonical re-arm path: `String.write(to:atomically:encoding:)` writes
    /// to a temp file and renames it over the target, invalidating the original fd.
    /// The watcher must detect the `.rename`/`.delete` event, re-open the path, and
    /// fire `onChange` for the new inode.
    @Test("atomic write (rename-replace) fires onChange via re-arm path")
    func atomicWriteFiresOnChange() async throws {
        try await withTempFile { url in
            let counter = Counter()

            let watcher = DocumentFileWatcher(url: url) { counter.increment() }
            watcher.start()

            // Atomic write = rename-replace → triggers .delete/.rename event.
            try "new content".write(to: url, atomically: true, encoding: .utf8)

            let received = await waitUntilEventually(deadline: .seconds(10)) { counter.value > 0 }
            watcher.stop()

            #expect(received, "onChange should fire after atomic (rename-replace) write")
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

    @Test("start retries an absent file and notifies after creation")
    func startAbsentNotifiesAfterCreation() async throws {
        let temporaryDirectory = try TemporaryDirectory(prefix: "DocumentFileWatcherTests")
        let url = temporaryDirectory.url.appendingPathComponent("created-later.md")
        let counter = Counter()
        let watcher = DocumentFileWatcher(url: url) { counter.increment() }

        watcher.start()
        try "created".write(to: url, atomically: false, encoding: .utf8)
        // Retry cadence stretches under full-suite load; the wait is
        // event-bounded, so a generous ceiling adds no latency when green.
        let received = await waitUntilEventually(deadline: .seconds(30)) { counter.value > 0 }
        watcher.stop()

        #expect(received, "successful initial retry should notify after the file appears")
        withExtendedLifetime(temporaryDirectory) {}
    }

    /// An in-place (non-atomic) write also fires `onChange`.
    @Test("in-place write fires onChange")
    func inPlaceWriteFiresOnChange() async throws {
        try await withTempFile { url in
            let counter = Counter()

            let watcher = DocumentFileWatcher(url: url) { counter.increment() }
            watcher.start()

            // Non-atomic: writes in-place, same inode, fires .write event.
            try "updated".write(to: url, atomically: false, encoding: .utf8)

            let received = await waitUntilEventually(deadline: .seconds(10)) { counter.value > 0 }
            watcher.stop()

            #expect(received, "onChange should fire after in-place write")
        }
    }

    /// A burst of writes coalesces to a small number of `onChange` calls.
    @Test("burst of writes coalesces (debounce)")
    func burstCoalescesToOne() async throws {
        try await withTempFile { url in
            let counter = Counter()

            let watcher = DocumentFileWatcher(url: url) { counter.increment() }
            watcher.start()

            // Write 5 times in rapid succession (well within the 100 ms debounce window).
            for i in 0..<5 {
                try "content \(i)".write(to: url, atomically: false, encoding: .utf8)
            }

            // Wait for the debounce window + a generous buffer.
            try await Task.sleep(nanoseconds: 500_000_000)  // 500 ms

            watcher.stop()

            // Debounce should have coalesced. Allow ≤4 to be resilient to OS scheduling,
            // but the key guarantee is not dozens.
            #expect(counter.value <= 4, "burst of 5 rapid writes should coalesce to ≤4 callbacks")
        }
    }

    /// `.immediate` opts out of coalescing entirely.
    ///
    /// Three writes 60 ms apart sit inside one default 100 ms window, which is
    /// purely trailing and restarts on every event — the default watcher
    /// delivers those as a single callback. A caller that coalesces downstream
    /// needs every event instead, because a continuous stream of sub-window
    /// writes can otherwise postpone delivery indefinitely.
    @Test("coalescing .immediate delivers every event")
    func immediateCoalescingDeliversEveryEvent() async throws {
        try await withTempFile { url in
            let counter = Counter()

            let watcher = DocumentFileWatcher(url: url, coalescing: .immediate) {
                counter.increment()
            }
            watcher.start()

            for i in 0..<3 {
                try "content \(i)".write(to: url, atomically: false, encoding: .utf8)
                try await Task.sleep(nanoseconds: 60_000_000)  // 60 ms — inside the default window
            }

            let delivered = await waitUntilEventually(deadline: .seconds(10)) { counter.value >= 3 }
            watcher.stop()

            #expect(
                delivered,
                "every write inside one default window must reach an .immediate watcher"
            )
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

    /// `stop()` is idempotent — calling it multiple times does not crash.
    @Test("stop() is idempotent")
    func stopIsIdempotent() async throws {
        try await withTempFile { url in
            let watcher = DocumentFileWatcher(url: url) {}
            watcher.start()
            watcher.stop()
            watcher.stop()
            watcher.stop()
            // No crash = pass.
        }
    }

    /// After `stop()`, writes do NOT fire `onChange`.
    @Test("no onChange fires after stop()")
    func noFireAfterStop() async throws {
        try await withTempFile { url in
            let counter = Counter()

            let watcher = DocumentFileWatcher(url: url) { counter.increment() }
            watcher.start()
            watcher.stop()

            // Write after stop.
            try "post-stop write".write(to: url, atomically: true, encoding: .utf8)

            // Wait longer than the debounce window.
            try await Task.sleep(nanoseconds: 400_000_000)
            #expect(counter.value == 0, "no onChange should fire after stop()")
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
