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
    /// Session ids are provider-native. Claude Code and Codex use UUIDs,
    /// OpenCode uses `ses_` tokens, and Pi also permits caller-selected ids.
    /// Validation therefore belongs to the source instead of imposing one
    /// provider's representation on every integration.
    public func validatedProviderSessionID(_ raw: String?) -> String? {
        guard let raw, raw.utf8.count <= Self.maximumProviderSessionIDByteCount else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        switch self {
        case .claudeCode, .codex:
            guard UUID(uuidString: trimmed) != nil else { return nil }
            return trimmed.lowercased()
        case .openCode:
            guard trimmed.utf8.count > 4,
                trimmed.hasPrefix("ses_"),
                trimmed.unicodeScalars.dropFirst(4).allSatisfy(\.isASCIIAlphaNumeric)
            else { return nil }
            return trimmed
        case .pi, .grok:
            guard let first = trimmed.unicodeScalars.first,
                let last = trimmed.unicodeScalars.last,
                first.isASCIIAlphaNumeric,
                last.isASCIIAlphaNumeric,
                trimmed.unicodeScalars.allSatisfy({
                    $0.isASCIIAlphaNumeric || $0 == "-" || $0 == "_" || $0 == "."
                })
            else { return nil }
            return trimmed
        case .unknown:
            return nil
        }
    }
}

private extension Unicode.Scalar {
    var isASCIIAlphaNumeric: Bool {
        (0x30...0x39).contains(value) || (0x41...0x5A).contains(value)
            || (0x61...0x7A).contains(value)
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
