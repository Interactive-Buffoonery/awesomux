import AwesoMuxBridgeProtocol
import AwesoMuxConfig
import AwesoMuxCore
import Foundation

/// Resolves the one provider config home an exact-identity transcript lookup
/// may inspect. The pane's provider selects the root; awesoMux never sweeps
/// other providers or guesses from a working directory.
enum AgentTranscriptPaneInputs {

    /// The provider config homes to try for a pane whose agent is `agentKind`,
    /// in order.
    ///
    /// Returns empty for providers without a supported transcript adapter.
    static func resolutionAttempts(
        for agentKind: AgentKind,
        integrations: AgentIntegrationsConfig,
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [(kind: AgentKind, configHome: URL, setup: AgentIntegrationSetup)] {
        guard
            agentKind == .claudeCode || agentKind == .codex || agentKind == .openCode
                || agentKind == .pi
        else { return [] }
        let setup = AgentConfigHome.setup(for: agentKind, in: integrations)
        func home(_ kind: AgentKind) -> URL? {
            AgentConfigHome.url(
                for: kind,
                setup: setup,
                homeDirectoryURL: homeDirectoryURL
            )
        }
        guard let configHome = home(agentKind) else { return [] }
        return [(kind: agentKind, configHome: configHome, setup: setup)]
    }
}
