import Foundation

/// Pure pre-kill revalidation for a *user-initiated* reap. Mirrors the launch
/// `DaemonGarbageCollector.sweep` revalidation: the panel poll is up to one
/// interval stale and the confirm dialog adds more delay, so the row the user
/// confirmed against may no longer describe the live daemon. This re-checks the
/// freshly-listed daemon against the target the user actually saw before any
/// `amx kill --force` goes out.
public enum DaemonReapGuard {
    /// The daemon the user confirmed against — its identity at confirm time plus
    /// the lifecycle that decided which confirm path (inline vs sheet) ran.
    public struct Target: Equatable, Sendable {
        public let id: TerminalSessionID
        public let pid: Int32
        public let createdEpoch: Int
        public let lifecycle: DaemonLifecycle

        public init(id: TerminalSessionID, pid: Int32, createdEpoch: Int, lifecycle: DaemonLifecycle) {
            self.id = id
            self.pid = pid
            self.createdEpoch = createdEpoch
            self.lifecycle = lifecycle
        }
    }

    /// Whether the reap may proceed given the daemon freshly re-listed for the
    /// target id (`nil` when the id is gone or `amx list` couldn't be parsed).
    ///
    /// - Identity (all lifecycles): `current` must exist and match the target's
    ///   `pid` + `createdEpoch`, so a recycled or restarted id is never killed.
    /// - Orphan classes (`.abandoned` / `.expired`): additionally require
    ///   `clients == 0` — if a restore-attach or a reopened workspace reattached
    ///   the daemon since the user saw the "no owner" row, it's now live and the
    ///   confirm dialog's promise ("nothing restores it") no longer holds.
    /// - `.owned` / `.detachedRestorable`: the reap *intends* to kill a live
    ///   session, so identity is checked but `clients` is not.
    public static func mayReap(target: Target, current: LiveDaemon?) -> Bool {
        guard let current else { return false }
        guard current.pid == target.pid, current.createdEpoch == target.createdEpoch else { return false }

        switch target.lifecycle {
        case .abandoned, .expired:
            return current.clients == 0
        case .owned, .detachedRestorable, .inUseElsewhere:
            return true
        }
    }
}
