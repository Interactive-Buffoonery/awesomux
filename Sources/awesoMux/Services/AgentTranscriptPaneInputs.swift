import AwesoMuxBridgeProtocol
import AwesoMuxConfig
import AwesoMuxCore
import Foundation

/// Resolves the one provider config home an exact-identity transcript lookup
/// may inspect. The pane's provider selects the root; awesoMux never sweeps
/// other providers or guesses from a working directory.
enum AgentTranscriptPaneInputs {

    /// The exact session Open Agent Transcript should look up for this pane.
    ///
    /// Live identity wins while an agent is running. After sessionEnd the pane
    /// is a shell and the live latch is gone, so the last-ended identity is
    /// the only exact answer left. A live pane without a reported id does not
    /// inherit the previous session — that would reopen the old transcript
    /// against a new agent. Never guesses by working directory or sweeps
    /// other providers (ADR 0033).
    static func lookupIdentity(
        paneKind: AgentKind,
        liveSessionID: String?,
        lastEnded: AgentTranscriptIdentity?
    ) -> AgentTranscriptIdentity? {
        if let liveSessionID,
            let identity = AgentTranscriptIdentity(agentKind: paneKind, sessionID: liveSessionID)
        {
            return identity
        }
        guard paneKind == .shell else { return nil }
        return lastEnded
    }

    /// The provider config homes to try for a pane whose agent is `agentKind`,
    /// in order.
    ///
    /// Returns empty for providers without a supported transcript adapter.
    static func resolutionAttempts(
        for agentKind: AgentKind,
        integrations: AgentIntegrationsConfig,
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [(kind: AgentKind, configHome: URL)] {
        guard agentKind == .claudeCode || agentKind == .codex || agentKind == .pi else {
            return []
        }
        let setup = AgentConfigHome.setup(for: agentKind, in: integrations)
        func home(_ kind: AgentKind) -> URL? {
            AgentConfigHome.url(
                for: kind,
                setup: setup,
                homeDirectoryURL: homeDirectoryURL
            )
        }
        guard let configHome = home(agentKind) else { return [] }
        return [(kind: agentKind, configHome: configHome)]
    }

    /// Why Open Agent Transcript has nothing to resolve.
    ///
    /// A live unsupported pane names itself. After sessionEnd the pane is a
    /// shell, so the ended kind is what keeps OpenCode and Grok from reading as
    /// "unknown session". Kinds that do have an adapter still report missing
    /// identity — they write logs; we just don't know which file.
    static func emptyLookupReason(
        paneKind: AgentKind,
        lastEndedKind: AgentKind?
    ) -> AgentTranscriptUnavailable {
        if paneKind != .shell {
            return .unsupportedAgent(paneKind)
        }
        if let lastEndedKind, lastEndedKind != .shell,
            lastEndedKind != .claudeCode, lastEndedKind != .codex, lastEndedKind != .pi
        {
            return .unsupportedAgent(lastEndedKind)
        }
        return .noSessionIdentity
    }
}
