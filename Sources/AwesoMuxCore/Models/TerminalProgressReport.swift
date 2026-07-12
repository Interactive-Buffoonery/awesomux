// Deliberately not `Codable`, matching `ForegroundProcessLiveness`'s
// runtime-only precedent — `progressReport` is already excluded from
// `TerminalPane.CodingKeys`, and dropping `Codable` here means a future
// refactor can't accidentally wire it back into persistence.
public struct TerminalProgressReport: Hashable, Sendable {
    public enum State: String, Codable, Hashable, Sendable {
        case remove
        case set
        case error
        case indeterminate
        case pause
    }

    public var state: State
    public var progress: UInt8?

    public init(state: State, progress: UInt8? = nil) {
        self.state = state
        self.progress = Self.normalizedProgress(progress, for: state)
    }

    public var isVisible: Bool {
        state != .remove
    }

    private static func normalizedProgress(_ progress: UInt8?, for state: State) -> UInt8? {
        guard state != .remove, state != .indeterminate, let progress else {
            return nil
        }

        return min(progress, 100)
    }
}
