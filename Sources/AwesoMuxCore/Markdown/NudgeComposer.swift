import AwesoMuxBridgeProtocol
import Foundation

/// Inputs for a provider-aware annotation handoff. The annotation payloads never
/// cross this boundary: the agent reads them from the file after the user stages
/// the prompt.
public struct AnnotationHandoffInput: Equatable, Sendable {
    public let provider: PlanAnnotationAuthor
    public let displayPath: String
    public let selectedAnnotationID: String?
    public let openAnnotationIDs: [String]

    public init(
        provider: PlanAnnotationAuthor,
        displayPath: String,
        selectedAnnotationID: String? = nil,
        openAnnotationIDs: [String] = []
    ) {
        self.provider = provider
        self.displayPath = displayPath
        self.selectedAnnotationID = selectedAnnotationID
        self.openAnnotationIDs = openAnnotationIDs
    }
}

public extension PlanAnnotationAuthor {
    /// Bridges the verified runtime provider identity to the exact `by=` value
    /// persisted in AMX markers. Grok and shells are intentionally not in the
    /// annotation protocol.
    init?(agentKind: AgentKind) {
        switch agentKind {
        case .claudeCode: self = .claudeCode
        case .codex: self = .codex
        case .pi: self = .pi
        case .openCode: self = .opencode
        case .grok, .shell: return nil
        }
    }

    var displayName: String {
        switch self {
        case .user: "User"
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .pi: "Pi"
        case .opencode: "OpenCode"
        }
    }
}

/// Composes the plain-English nudge text injected into the document's associated
/// terminal when the user taps a document handoff action.
public enum NudgeComposer {
    /// Legacy generic composition retained for callers and migration guidance.
    public static func text(displayPath: String) -> String {
        compose(
            displayPath: displayPath,
            provider: nil,
            selectedAnnotationID: nil,
            openAnnotationIDs: []
        )
    }

    /// Composes a self-contained, provider-aware review handoff. The nudge is
    /// staged (no trailing newline) so the user sees it at the prompt and can
    /// review or edit it before pressing Return.
    public static func text(_ input: AnnotationHandoffInput) -> String {
        compose(
            displayPath: input.displayPath,
            provider: input.provider,
            selectedAnnotationID: input.selectedAnnotationID,
            openAnnotationIDs: input.openAnnotationIDs
        )
    }

    private static func compose(
        displayPath: String,
        provider: PlanAnnotationAuthor?,
        selectedAnnotationID: String?,
        openAnnotationIDs: [String]
    ) -> String {
        let selectedID = sanitizedIdentifier(selectedAnnotationID)
        let orderedOpenIDs = orderedUniqueIdentifiers(openAnnotationIDs)
        let remainingOpenIDs = orderedOpenIDs.filter { $0 != selectedID }

        var context = ""
        if let provider {
            context += "You are \(provider.displayName); use provider id \(provider.rawValue) when replying. "
        }
        if let selectedID {
            context += "Prioritize annotation \(selectedID) first. "
        }
        if remainingOpenIDs.isEmpty {
            context += "There are no other open annotation ids. "
        } else {
            context += "Other open annotation ids, in document order: \(remainingOpenIDs.joined(separator: ", ")). "
        }

        // POSIX single-quote the path. The nudge is staged into a live PTY; if the
        // target happens to be a shell (agent detection isn't reliable yet) and the
        // user presses Return, an unquoted filename like `notes; rm -rf ~ #.md` would
        // run as a command. Single-quoting makes the path an inert literal in any
        // POSIX shell, while still reading clearly as a path to an agent.
        return "Address my review annotations in \(shellSingleQuoted(displayPath)). "
            + context
            + "Read the file yourself; the prompt contains ids only, not hidden annotation text. "
            + "Annotations are HTML comment markers: <!-- USER COMMENT N: … --> or "
            + "<!-- AMX id=… by=… …: … -->. A marker right after <mark>highlighted</mark> text "
            + "is a request about that span; the single AMX marker on its own line is the note "
            + "about the whole document. intent=replace carries suggested replacement text for the span; "
            + "intent=delete asks you to remove it. When you've handled one: for AMX markers, "
            + "set status=resolved inside the marker (keep it so I can verify) or remove the "
            + "<mark> wrapper and marker; for USER COMMENT markers, remove the wrapper and "
            + "marker. Inline annotations can have replies using "
            + "<!-- AMX re=<id> by=\(provider?.rawValue ?? "your-provider-id"): note -->"
            + " and the document note has no replies."
    }

    private static func sanitizedIdentifier(_ value: String?) -> String? {
        guard let value else { return nil }
        let sanitized = value.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
            .map(String.init)
            .joined()
        let trimmed = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func orderedUniqueIdentifiers(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            guard let sanitized = sanitizedIdentifier(value), seen.insert(sanitized).inserted else {
                return nil
            }
            return sanitized
        }
    }

    /// Wraps a string in POSIX single quotes, escaping any embedded single quote via
    /// the standard `'\''` close-escape-reopen idiom. Safe for any shell input.
    static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
