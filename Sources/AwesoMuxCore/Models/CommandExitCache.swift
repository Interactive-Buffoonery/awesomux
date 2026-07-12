import Foundation

public struct CommandExitCache: Equatable, Sendable {
    /// How long a cached non-zero command exit code remains eligible for a
    /// following process-exit close callback. This attributes Ghostty's
    /// near-immediate command-finished callback to the later close callback.
    /// It is currently also `2.0` seconds like
    /// `VisibleTextAgentStateReducer.runtimeEventSuppressionWindow`, but that
    /// reducer protects explicit side-channel state from stale visible-text
    /// fallback; keep the constants separate so tuning one race window does not
    /// silently tune the other.
    public static let defaultFreshnessWindow: TimeInterval = 2.0

    public private(set) var exitCode: Int16?
    public private(set) var recordedAt: TimeInterval?

    public init(exitCode: Int16? = nil, recordedAt: TimeInterval? = nil) {
        self.exitCode = exitCode
        self.recordedAt = recordedAt
    }

    public mutating func record(exitCode: Int16, at time: TimeInterval) {
        self.exitCode = exitCode
        recordedAt = time
    }

    public mutating func clear() {
        exitCode = nil
        recordedAt = nil
    }

    public func hasFreshNonZeroExitCode(
        now: TimeInterval,
        freshnessWindow: TimeInterval = Self.defaultFreshnessWindow
    ) -> Bool {
        guard let exitCode, exitCode != 0 else { return false }
        guard let recordedAt else { return false }

        let age = now - recordedAt
        return age >= 0 && age <= freshnessWindow
    }

    public func shouldSignalSiblingPaneExit(
        now: TimeInterval,
        paneCount: Int,
        freshnessWindow: TimeInterval = Self.defaultFreshnessWindow
    ) -> Bool {
        guard paneCount > 1 else { return false }
        return hasFreshNonZeroExitCode(now: now, freshnessWindow: freshnessWindow)
    }
}
