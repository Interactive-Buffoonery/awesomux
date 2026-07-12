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
    var priority: Int {
        switch self {
        case .permissionPrompt, .userInputRequired:
            2
        case .processError:
            1
        case .bell, .desktopNotification, .unknown:
            0
        }
    }
}

public enum AgentDisplayState: String, CaseIterable, Codable, Hashable, Sendable {
    case idle
    case running
    case waiting
    case thinking
    case output
    case needsAttention
    case done
    case error

    public init(
        executionState: AgentExecutionState,
        attentionReason: AttentionReason?
    ) {
        // A dead pane (`.done`/`.error`) shows through as such: its recovery
        // hint is the most useful thing on screen, and a lingering low-priority
        // attentionReason (bell / desktopNotification / processError / unknown)
        // from before the exit must not mask it behind `.needsAttention`
        // (INT-506). Exception: a still-pending high-priority prompt
        // (permissionPrompt / userInputRequired) outranks the recovery hint —
        // an unanswered permission request stays loud even on a dead pane.
        if let attentionReason {
            let deadPane = executionState == .done || executionState == .error
            if !deadPane
                || attentionReason.priority >= AttentionReason.permissionPrompt.priority {
                self = .needsAttention
                return
            }
        }

        self = Self(executionState: executionState)
    }

    public init(executionState: AgentExecutionState) {
        switch executionState {
        case .idle:
            self = .idle
        case .running:
            self = .running
        case .waiting:
            self = .waiting
        case .thinking:
            self = .thinking
        case .output:
            self = .output
        case .done:
            self = .done
        case .error:
            self = .error
        }
    }

    public var executionState: AgentExecutionState? {
        switch self {
        case .idle:
            .idle
        case .running:
            .running
        case .waiting:
            .waiting
        case .thinking:
            .thinking
        case .output:
            .output
        case .done:
            .done
        case .error:
            .error
        case .needsAttention:
            nil
        }
    }

    public var attentionReason: AttentionReason? {
        self == .needsAttention ? .unknown : nil
    }

    public var label: String {
        localizedLabel()
    }

    public func localizedLabel(
        bundle: Bundle = .main,
        locale: Locale = .current
    ) -> String {
        switch self {
        case .idle:
            String(localized: "Idle", bundle: bundle, locale: locale, comment: "Agent state label")
        case .running:
            String(localized: "Running", bundle: bundle, locale: locale, comment: "Agent state label")
        case .waiting:
            String(localized: "Waiting", bundle: bundle, locale: locale, comment: "Agent state label")
        case .thinking:
            String(localized: "Thinking", bundle: bundle, locale: locale, comment: "Agent state label")
        case .output:
            String(localized: "Output", bundle: bundle, locale: locale, comment: "Agent state label")
        case .needsAttention:
            // Matches the design-system `AwState.needs` wording so every spoken
            // surface (sidebar row, peek card, VoiceOver rotor) agrees. Locked by
            // a test that asserts `label == awState.label` for every case.
            String(localized: "Needs input", bundle: bundle, locale: locale, comment: "Agent state label")
        case .done:
            String(localized: "Done", bundle: bundle, locale: locale, comment: "Agent state label")
        case .error:
            String(localized: "Error", bundle: bundle, locale: locale, comment: "Agent state label")
        }
    }

    /// Presentation urgency for choosing the louder state when two signals
    /// compete. Lower values are more urgent. The order is explicit policy:
    /// every new state must choose its own position in this switch instead of
    /// relying on raw values or declaration order.
    public var priority: Int {
        switch self {
        case .needsAttention:
            1
        case .error:
            2
        case .thinking:
            3
        case .done:
            4
        case .output:
            5
        case .waiting:
            6
        case .running:
            7
        case .idle:
            8
        }
    }

    public var triggersNotification: Bool {
        self == .needsAttention
    }

    /// Returns whether this state is at least as urgent as `other` using the
    /// explicit presentation policy in `priority`; lower priority values are
    /// more urgent.
    public func isAtLeastAsUrgent(as other: AgentDisplayState) -> Bool {
        priority <= other.priority
    }

    public var refreshesAgentActivity: Bool {
        switch self {
        case .running, .thinking, .output:
            true
        case .idle, .waiting, .needsAttention, .done, .error:
            false
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        // Tolerate the v0 'finished' → 'done' rename so snapshots written
        // before the vocabulary expansion still load.
        let normalized = raw == "finished" ? "done" : raw
        guard let state = AgentDisplayState(rawValue: normalized) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown AgentDisplayState raw value: \(raw)"
            )
        }
        self = state
    }
}

public typealias AgentState = AgentDisplayState
