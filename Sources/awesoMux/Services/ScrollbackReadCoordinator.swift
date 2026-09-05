import Foundation

/// Pins native ownership until an off-main extraction has returned. All frees
/// and runtime reloads remain on the main actor; cancellation only drops UI output.
@MainActor
final class ScrollbackReadCoordinator {
    private var active: Set<UInt> = []
    private var pendingFrees: [UInt: () -> Void] = [:]
    private var pendingReload: (() -> Void)?

    func read(
        surfaceID: UInt,
        operation: @escaping @Sendable () -> ScrollbackDumpReader.Result
    ) async -> ScrollbackDumpReader.Result {
        guard pendingReload == nil, active.insert(surfaceID).inserted else { return .busy }
        defer {
            active.remove(surfaceID)
            pendingFrees.removeValue(forKey: surfaceID)?()
            if active.isEmpty, let reload = pendingReload {
                pendingReload = nil
                reload()
            }
        }
        // Native lock waits must not occupy Swift's cooperative executor.
        // Cancellation only drops UI output; the worker must finish before free.
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: operation())
            }
        }
    }

    func deferFree(surfaceID: UInt, operation: @escaping () -> Void) -> Bool {
        guard active.contains(surfaceID) else { return false }
        precondition(pendingFrees[surfaceID] == nil)
        pendingFrees[surfaceID] = operation
        return true
    }

    func deferReload(operation: @escaping () -> Void) -> Bool {
        guard !active.isEmpty else { return false }
        pendingReload = operation
        return true
    }
}
