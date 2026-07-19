import Dispatch
import Foundation
import OSLog

protocol GhosttyFaultLogSource: Sendable {
    func recentFaultCount(subsystem: String, category: String, since: Date) async -> Int
}

/// Reads awesoMux's own process log via `OSLogStore`. Ghostty's Zig
/// `std.log` routes fault/error-level entries here under
/// `subsystem: "com.mitchellh.ghostty"` with no Swift-side hookup —
/// this is the only signal awesoMux has for Zig-side event-loop faults
/// like the libxev kqueue submission-queue corruption
/// (mitchellh/libxev#122, Interactive-Buffoonery/awesomux#562).
///
/// `OSLogStore.getEntries` performs synchronous XPC and can stall indefinitely.
/// The dedicated serial queue keeps that work off the main actor while also
/// confining the cached, non-Sendable store to one executor. Admission remains
/// held until queued work exits so cancelled watchdogs cannot stack replacements.
final class OSLogGhosttyFaultSource: GhosttyFaultLogSource, @unchecked Sendable {
    typealias Query =
        @Sendable (
            _ subsystem: String,
            _ category: String,
            _ since: Date
        ) -> Int

    private let queue = DispatchQueue(label: "dev.awesomux.ghostty-fault-log")
    private let admissionLock = NSLock()
    private let queryOverride: Query?
    private var queryIsAdmitted = false
    private var store: OSLogStore?

    init(query: Query? = nil) {
        self.queryOverride = query
    }

    func recentFaultCount(subsystem: String, category: String, since: Date) async -> Int {
        guard admitQuery() else { return 0 }
        let completion = FaultQueryCompletion()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                completion.install(continuation)
                queue.async { [self] in
                    defer { releaseQuery() }
                    guard !completion.isCancelled else { return }
                    completion.resume(
                        queryFaultCount(
                            subsystem: subsystem,
                            category: category,
                            since: since
                        )
                    )
                }
            }
        } onCancel: {
            completion.cancel()
        }
    }

    private func admitQuery() -> Bool {
        admissionLock.withLock {
            guard !queryIsAdmitted else { return false }
            queryIsAdmitted = true
            return true
        }
    }

    private func releaseQuery() {
        admissionLock.withLock { queryIsAdmitted = false }
    }

    private func queryFaultCount(subsystem: String, category: String, since: Date) -> Int {
        if let queryOverride {
            return queryOverride(subsystem, category, since)
        }
        if store == nil {
            store = try? OSLogStore(scope: .currentProcessIdentifier)
        }
        guard let store else {
            return 0
        }
        let position = store.position(date: since)
        let predicate = NSPredicate(
            format: "subsystem == %@ AND category == %@",
            subsystem,
            category
        )
        guard let entries = try? store.getEntries(at: position, matching: predicate) else {
            return 0
        }
        return
            entries
            .compactMap { $0 as? OSLogEntryLog }
            .filter { $0.level == .fault || $0.level == .error }
            .count
    }
}

private final class FaultQueryCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Int, Never>?
    private var cancelled = false
    private var resumed = false

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func install(_ continuation: CheckedContinuation<Int, Never>) {
        let shouldResume = lock.withLock {
            self.continuation = continuation
            guard cancelled else { return false }
            resumed = true
            self.continuation = nil
            return true
        }
        if shouldResume {
            continuation.resume(returning: 0)
        }
    }

    func cancel() {
        let continuation: CheckedContinuation<Int, Never>? = lock.withLock {
            cancelled = true
            guard !resumed else { return nil }
            resumed = true
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(returning: 0)
    }

    func resume(_ result: Int) {
        let continuation: CheckedContinuation<Int, Never>? = lock.withLock {
            guard !resumed else { return nil }
            resumed = true
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(returning: result)
    }
}
