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
/// confining the cached, non-Sendable store to one executor.
final class OSLogGhosttyFaultSource: GhosttyFaultLogSource, @unchecked Sendable {
    typealias Query =
        @Sendable (
            _ subsystem: String,
            _ category: String,
            _ since: Date
        ) -> Int

    private let queue = DispatchQueue(label: "dev.awesomux.ghostty-fault-log")
    private let queryOverride: Query?
    private var store: OSLogStore?

    init(query: Query? = nil) {
        self.queryOverride = query
    }

    func recentFaultCount(subsystem: String, category: String, since: Date) async -> Int {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(
                    returning: queryFaultCount(
                        subsystem: subsystem,
                        category: category,
                        since: since
                    )
                )
            }
        }
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
