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
    /// This is also the one place a provider id is put into canonical form, and
    /// it has to be: `UUID(uuidString:)` accepts either case, while three
    /// downstream consumers compare the value literally — the importer's
    /// filename match, the transcript cache's slot hash (an uppercase id would
    /// hash to a second slot, producing a duplicate file and a duplicate tab
    /// for one session), and the excluded-id membership test. Every path that
    /// can set the field from outside the app — the hook producer, the
    /// same-UID-writable event file, and the bridge — passes through here, so
    /// normalising once here is enough and no consumer re-folds. Lowercase
    /// rather than `UUID.uuidString`'s uppercase, because both providers write
    /// lowercase and the filename on disk is what a lookup has to match.
    ///
    /// ponytail: `.grok` is exempt from both the UUID shape and the case fold,
    /// and only has to be a single whitespace-free token. Its real id format is
    /// unverified here, so folding case could merge two ids that the provider
    /// means to be distinct. The value is used solely for equality — the
    /// child-agent drop rule, and now also the transcript fallback's
    /// excluded-id set — so a tighter gate would silently disable those rather
    /// than harden them. The tripwire is unchanged: tighten this once a real
    /// Grok id is observed, or the moment anything consumes a Grok session id
    /// as a path or a command. (`AgentTranscriptImporter.Provider` and
    /// `AgentTranscriptIdentity` both reject `.grok` outright, which is what
    /// keeps that from happening by accident.)
    public func validatedProviderSessionID(_ raw: String?) -> String? {
        guard let raw, raw.utf8.count <= Self.maximumProviderSessionIDByteCount else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard self != .grok else {
            return trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil ? trimmed : nil
        }
        guard UUID(uuidString: trimmed) != nil else { return nil }
        return trimmed.lowercased()
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
