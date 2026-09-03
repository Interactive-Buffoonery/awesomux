import AwesoMuxBridgeProtocol
import Foundation

/// Durable provenance for a document tab showing an app-rendered agent
/// transcript: which provider, and which of its sessions.
///
/// This is the tab's identity; the rendered `.md` under the transcript cache is
/// regenerable implementation storage, exactly as `ResourceIdentity` is the
/// identity of a remote Markdown snapshot and its downloaded cache file is not.
///
/// It is stored ON the document rather than asked of the adjacent pane because
/// a pane outlives the session whose transcript is open beside it. Open
/// session A's transcript, exit that agent, start session B in the same
/// terminal: an accessor that consults the pane now answers B, and a Resume
/// control bound to it would resume the wrong session. A tab answers with the
/// session it was actually rendered from, forever.
///
/// Validity is a construction invariant. Both initialisers reject anything the
/// value could not safely become downstream — a transcript filename component
/// and text staged into a live PTY — so no consumer has to re-check, and there
/// is no way to hold an invalid instance.
public struct AgentTranscriptIdentity: Hashable, Sendable {
    public let agentKind: AgentKind
    /// A canonical provider-native session id.
    public let sessionID: String

    /// Returns `nil` unless `agentKind` is a provider whose transcript layout
    /// awesoMux knows and `sessionID` passes that provider's validation.
    ///
    /// The provider allowlist covers every transcript storage adapter.
    public init?(agentKind: AgentKind, sessionID: String) {
        guard let source = Self.runtimeSource(for: agentKind) else { return nil }
        guard let validated = source.validatedProviderSessionID(sessionID) else {
            return nil
        }
        self.agentKind = agentKind
        self.sessionID = validated
    }

    /// Whether awesoMux has a transcript storage adapter for this provider.
    public static func supports(agentKind: AgentKind) -> Bool {
        runtimeSource(for: agentKind) != nil
    }

    private static func runtimeSource(for agentKind: AgentKind) -> AgentRuntimeSource? {
        switch agentKind {
        case .claudeCode: .claudeCode
        case .codex: .codex
        case .openCode: .openCode
        case .pi: .pi
        case .grok, .shell, .generic: nil
        }
    }

    /// The provenance of a transcript that was just resolved and opened.
    /// Fails only for a kind `AgentTranscriptImporter` would itself have
    /// rejected, so in practice it succeeds for every transcript it is handed.
    public init?(_ transcript: AgentTranscript) {
        self.init(agentKind: transcript.agentKind, sessionID: transcript.sessionID)
    }

    /// The tab title for a transcript document. The file it points at is named
    /// after a hash, so the identity is the only readable name available.
    public var documentTitle: String {
        String(
            localized: "\(agentKind.rawValue) Transcript",
            comment: "Document tab title for a rendered agent transcript, e.g. 'Claude Code Transcript'"
        )
    }
}

extension AgentTranscriptIdentity: Codable {
    private enum CodingKeys: String, CodingKey {
        case agentKind
        case sessionID
    }

    /// Re-validates on the way in. A snapshot is a same-UID-writable file, so a
    /// persisted identity is untrusted input and gets the same gate as a fresh
    /// one rather than being reconstructed around it.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard
            let identity = AgentTranscriptIdentity(
                agentKind: try container.decode(AgentKind.self, forKey: .agentKind),
                sessionID: try container.decode(String.self, forKey: .sessionID)
            )
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .sessionID,
                in: container,
                debugDescription:
                    "An agent transcript identity requires a supported provider and a valid provider session id."
            )
        }
        self = identity
    }
}
