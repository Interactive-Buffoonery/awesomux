import Foundation
import OSLog

protocol GhosttyFaultLogSource {
    func recentFaultCount(subsystem: String, category: String, since: Date) -> Int
}

/// Reads awesoMux's own process log via `OSLogStore`. Ghostty's Zig
/// `std.log` routes fault/error-level entries here under
/// `subsystem: "com.mitchellh.ghostty"` with no Swift-side hookup —
/// this is the only signal awesoMux has for Zig-side event-loop faults
/// like the libxev kqueue submission-queue corruption
/// (mitchellh/libxev#122, Interactive-Buffoonery/awesomux#562).
final class OSLogGhosttyFaultSource: GhosttyFaultLogSource {
    // ponytail: class (not struct) so this can be cached as `lazy var`
    // without forcing `mutating func` onto the protocol requirement —
    // opening an OSLogStore per poll was the actual cost here.
    private lazy var store: OSLogStore? = try? OSLogStore(scope: .currentProcessIdentifier)

    func recentFaultCount(subsystem: String, category: String, since: Date) -> Int {
        guard let store else {
            return 0
        }
        let position = store.position(date: since)
        let predicate = NSPredicate(
            format: "subsystem == %@ AND category == %@",
            subsystem, category
        )
        guard let entries = try? store.getEntries(at: position, matching: predicate) else {
            return 0
        }
        return entries
            .compactMap { $0 as? OSLogEntryLog }
            .filter { $0.level == .fault || $0.level == .error }
            .count
    }
}
