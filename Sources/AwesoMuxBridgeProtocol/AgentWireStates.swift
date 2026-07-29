import Foundation

public enum AgentExecutionState: String, CaseIterable, Codable, Hashable, Sendable {
    case idle
    case running
    case waiting
    case thinking
    case output
    /// An agent run or detected agent command completed successfully. Terminal
    /// process-exit workspace close does not set this state.
    case done
    /// A live detector/runtime path observed an error while the shell is
    /// still running, or restored state carried an unresolved error.
    case error

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        // Tolerate the v0 'finished' → 'done' rename so snapshots written
        // before the vocabulary expansion still load.
        let normalized = raw == "finished" ? "done" : raw
        guard let state = AgentExecutionState(rawValue: normalized) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown AgentExecutionState raw value: \(raw)"
            )
        }
        self = state
    }
}

public enum AttentionReason: String, CaseIterable, Codable, Hashable, Sendable {
    case bell
    case desktopNotification
    case permissionPrompt
    case userInputRequired
    case processError
    case unknown

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = AttentionReason(rawValue: raw) ?? .unknown
    }

    /// Higher outranks lower. A pane awaiting explicit user action
    /// (`permissionPrompt`/`userInputRequired`) must survive a lower-priority
    /// signal arriving after it (e.g. a `.bell`) — see INT-506. `processError`
    /// sits in between: it matters, but not as much as a live prompt still
    /// needing an answer.
    public var priority: Int {
        switch self {
        case .permissionPrompt, .userInputRequired:
            2
        case .processError:
            1
        case .bell, .desktopNotification, .unknown:
            0
        }
    }

    /// True for the reasons that block on a human answer: the agent has stopped
    /// and will not proceed until a person responds, as opposed to a reason that
    /// merely reports something worth noticing. Single definition of
    /// "high-priority attention" for every consumer of this protocol.
    ///
    /// A consumer may retract one of these only on knowledge that the prompt was
    /// answered or became unanswerable — never on an inference drawn from the
    /// agent going quiet, which is exactly what a blocked agent does.
    public var awaitsExplicitAnswer: Bool {
        priority >= AttentionReason.permissionPrompt.priority
    }
}
