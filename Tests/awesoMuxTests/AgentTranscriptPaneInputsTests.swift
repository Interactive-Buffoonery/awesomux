import AwesoMuxBridgeProtocol
import AwesoMuxConfig
import Foundation
import Testing

@testable import awesoMux

@Suite("Agent transcript pane inputs")
struct AgentTranscriptPaneInputsTests {
    private static let home = URL(fileURLWithPath: "/Users/tester")

    private func attempts(
        for kind: AgentKind,
        integrations: AgentIntegrationsConfig = AgentIntegrationsConfig()
    ) -> [(kind: AgentKind, configHome: URL, setup: AgentIntegrationSetup)] {
        AgentTranscriptPaneInputs.resolutionAttempts(
            for: kind,
            integrations: integrations,
            homeDirectoryURL: Self.home
        )
    }

    @Test("a supported pane resolves only its own provider")
    func supportedPaneResolvesOnlyItsProvider() {
        #expect(attempts(for: .claudeCode).map(\.kind) == [.claudeCode])
        #expect(attempts(for: .codex).map(\.kind) == [.codex])
    }

    @Test("a shell pane never guesses which provider owned a session")
    func shellPaneDoesNotSweepProviders() {
        #expect(attempts(for: .shell).isEmpty)
    }

    @Test("Pi and OpenCode resolve only their own provider roots")
    func additionalProvidersResolveTheirOwnRoots() {
        #expect(attempts(for: .openCode).first?.configHome.path == "/Users/tester/.config/opencode")
        #expect(attempts(for: .pi).first?.configHome.path == "/Users/tester/.pi/agent")
        #expect(attempts(for: .grok).isEmpty)
    }

    @Test("a relocated config home is honored")
    func configHomeOverrideIsHonored() {
        let integrations = AgentIntegrationsConfig(
            claudeCode: AgentIntegrationSetup(enabled: true, configHome: "/opt/claude-home")
        )

        #expect(
            attempts(for: .claudeCode, integrations: integrations).first?.configHome.path
                == "/opt/claude-home"
        )
    }
}
