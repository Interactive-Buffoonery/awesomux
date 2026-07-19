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
@Suite("DocumentFileWatcher")
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

    /// Polls `condition` every 20 ms until it returns `true` or the timeout expires.
    private func awaitCondition(
        timeout seconds: Double,
        condition: @escaping () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
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

            // Give the watcher a tick to arm.
            try await Task.sleep(nanoseconds: 50_000_000)  // 50 ms

            // Atomic write = rename-replace → triggers .delete/.rename event.
            try "new content".write(to: url, atomically: true, encoding: .utf8)

            // Wait up to 3 seconds for the debounced onChange.
            let received = await awaitCondition(timeout: 3.0) { counter.value > 0 }
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
            try await Task.sleep(nanoseconds: 50_000_000)

            try "first event".write(to: url, atomically: false, encoding: .utf8)
            try await Task.sleep(nanoseconds: 30_000_000)
            try FileManager.default.removeItem(at: url)
            let missingCallback = await awaitCondition(timeout: 1.0) {
                callbackFileStates.values.contains(false)
            }
            try "recreated".write(to: url, atomically: false, encoding: .utf8)
            let rearmedCallback = await awaitCondition(timeout: 1.0) {
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
            try await Task.sleep(nanoseconds: 50_000_000)

            try FileManager.default.removeItem(at: url)
            let received = await awaitCondition(timeout: 5.0) { counter.value > 0 }
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
        try await Task.sleep(nanoseconds: 50_000_000)
        try "created".write(to: url, atomically: false, encoding: .utf8)
        // Retry cadence stretches under full-suite load; the wait is
        // event-bounded, so a generous ceiling adds no latency when green.
        let received = await awaitCondition(timeout: 30.0) { counter.value > 0 }
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

            try await Task.sleep(nanoseconds: 50_000_000)

            // Non-atomic: writes in-place, same inode, fires .write event.
            try "updated".write(to: url, atomically: false, encoding: .utf8)

            let received = await awaitCondition(timeout: 3.0) { counter.value > 0 }
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

            try await Task.sleep(nanoseconds: 50_000_000)

            // Write 5 times in rapid succession (well within the 100 ms debounce window).
            for i in 0..<5 {
                try "content \(i)".write(to: url, atomically: false, encoding: .utf8)
            }

            // Wait for the debounce window + a generous buffer.
            try await Task.sleep(nanoseconds: 500_000_000)  // 500 ms

            watcher.stop()

            // Debounce should have coalesced. Allow ≤3 to be resilient to OS scheduling,
            // but the key guarantee is not dozens.
            #expect(counter.value <= 3, "burst of 5 rapid writes should coalesce to ≤3 callbacks")
        }
    }

    /// `stop()` is idempotent — calling it multiple times does not crash.
    @Test("stop() is idempotent")
    func stopIsIdempotent() async throws {
        try await withTempFile { url in
            let watcher = DocumentFileWatcher(url: url) {}
            watcher.start()
            try await Task.sleep(nanoseconds: 20_000_000)
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
            try await Task.sleep(nanoseconds: 50_000_000)
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
