import Foundation

public enum AgentRuntimeSource: String, Codable, Sendable {
    case claudeCode = "claude-code"
    case codex
    case openCode = "opencode"
    case pi
    case grok
    case unknown

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = AgentRuntimeSource(rawValue: rawValue) ?? .unknown
    }

    /// Maps a runtime event source to the agent kind it implies, used as a
    /// fallback when the event omits an explicit `kind`. Returns nil for
    /// sources without a corresponding AgentKind so `.shell` stays `.shell`.
    public var inferredAgentKind: AgentKind? {
        switch self {
        case .claudeCode:
            .claudeCode
        case .codex:
            .codex
        case .openCode:
            .openCode
        case .pi:
            .pi
        case .grok:
            .grok
        case .unknown:
            nil
        }
    }

    public var hasTrustworthySessionRestartBoundary: Bool {
        switch self {
        case .claudeCode, .pi:
            true
        case .codex, .openCode, .grok, .unknown:
            false
        }
    }

    /// Kept far below `AgentRuntimeEvent.maximumLineByteCount` (4 KiB). An
    /// unbounded id does not just make itself useless: it pushes the whole
    /// JSONL line past the cap, and the lifecycle transition riding along with
    /// it is dropped too.
    public static let maximumProviderSessionIDByteCount = 128

    /// Validates a provider-native session id at a trust boundary, returning
    /// nil for anything that fails. Callers drop only this field — the event
    /// it rides on still carries a load-bearing lifecycle transition.
    ///
    /// This is a trust boundary in both directions it can be written from: the
    /// event file is same-UID writable, and the bridge lets a remote host set
    /// the field. Downstream the value becomes a transcript filename component
    /// and text staged into a live PTY (`RichInputStaging` preserves newlines
    /// by design), so `x\nrm -rf ~` and `../../../tmp/evil` must not survive.
    /// Claude Code and Codex both report UUIDs — a Claude transcript filename
    /// *is* its session id, and Codex's `session_meta.payload.id` is a UUIDv7
    /// matching its rollout filename — so the UUID shape is the whole gate.
    ///
    /// ponytail: `.grok` is exempt from the UUID shape and only has to be a
    /// single whitespace-free token. Its real id format is unverified here and
    /// the value is used solely for equality (the child-agent drop rule), so a
    /// tighter gate would silently disable that rule rather than harden it.
    /// Tighten it once a real Grok id is observed, or the moment anything
    /// consumes a Grok session id as a path or a command.
    public func validatedProviderSessionID(_ raw: String?) -> String? {
        guard let raw, raw.utf8.count <= Self.maximumProviderSessionIDByteCount else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard self != .grok else {
            return trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil ? trimmed : nil
        }
        return UUID(uuidString: trimmed) == nil ? nil : trimmed
    }
}

public enum AgentRuntimePhase: String, Codable, Sendable {
    case sessionStart
    case promptSubmit
    case toolStart
    case toolEnd
    case notification
    case stop
    case sessionEnd
    case rename
    case openDocument = "open-document"
}
