import AwesoMuxConfig
import AwesoMuxCore
import Foundation
import Testing
@testable import awesoMux

@Suite
struct AgentRuntimeEnvironmentTests {
    private static let sessionID = UUID()
    private static let paneID = UUID()
    private static let eventFileURL = URL(fileURLWithPath: "/tmp/awesomux-agent-event.jsonl")

    @Test
    func injectsHelperPathWhenAvailable() {
        let hookURL = URL(fileURLWithPath: "/Applications/awesoMux.app/Contents/MacOS/awesoMuxAgentHook")
        let amxURL = URL(fileURLWithPath: "/Applications/awesoMux.app/Contents/MacOS/amx")
        let env = AgentRuntimeEnvironment(
            sessionID: Self.sessionID,
            paneID: Self.paneID,
            eventFileURL: Self.eventFileURL,
            enabledFileDropSources: [.openCode, .pi, .grok, .claudeCode, .codex],
            profileValue: "development:0123456789ab",
            agentHookURL: hookURL,
            amxURL: amxURL
        )

        #expect(Set(env.environment.keys) == Set(AgentRuntimeEnvironmentKey.paneScopedKeys))
        #expect(env.environment[AgentRuntimeEnvironmentKey.agentHook] == hookURL.path)
        #expect(env.environment[AgentRuntimeEnvironmentKey.amx] == amxURL.path)
        #expect(env.environment[AgentRuntimeEnvironmentKey.profile] == "development:0123456789ab")
        #expect(env.environment[AgentRuntimeEnvironmentKey.eventProtocol] == AgentRuntimeEvent.protocolName)
        #expect(env.environment[AgentRuntimeEnvironmentKey.sessionID] == Self.sessionID.uuidString)
        #expect(env.environment[AgentRuntimeEnvironmentKey.paneID] == Self.paneID.uuidString)
        #expect(env.environment[AgentRuntimeEnvironmentKey.eventFile] == Self.eventFileURL.path)
        #expect(env.environment[AgentRuntimeEnvironmentKey.enabledSources] == "opencode,pi")
    }

    @Test
    func omitsHelperPathWhenAbsent() {
        // Both URLs are injected explicitly here and above; the
        // executable-gated default lookup (`AmxBackend.bundledExecutableURL()`)
        // is source-inspected, not exercised by these tests.
        let env = AgentRuntimeEnvironment(
            sessionID: Self.sessionID,
            paneID: Self.paneID,
            eventFileURL: Self.eventFileURL,
            profileValue: "production",
            agentHookURL: nil,
            amxURL: nil
        )

        #expect(env.environment[AgentRuntimeEnvironmentKey.agentHook] == nil)
        #expect(env.environment[AgentRuntimeEnvironmentKey.amx] == nil)
        #expect(env.environment[AgentRuntimeEnvironmentKey.enabledSources] == "")
        #expect(env.environment[AgentRuntimeEnvironmentKey.profile] == "production")
        #expect(env.environment.count == 6)
    }

    @Test
    func amxKeyIsPaneScopedButNotHealthCheckRequired() {
        // Local-shell fallback panes have no amx daemon; the runtime health
        // check must not fail on the missing var.
        #expect(AgentRuntimeEnvironmentKey.paneScopedKeys.contains(AgentRuntimeEnvironmentKey.amx))
        #expect(!AgentRuntimeEnvironmentKey.healthCheckRequiredKeys.contains(AgentRuntimeEnvironmentKey.amx))
        #expect(AgentRuntimeEnvironmentKey.paneScopedKeys.contains(AgentRuntimeEnvironmentKey.profile))
        #expect(!AgentRuntimeEnvironmentKey.healthCheckRequiredKeys.contains(AgentRuntimeEnvironmentKey.profile))
    }

    @Test
    func consentGatesOnlyFileDropProviderEvents() {
        let consent = AgentRuntimeConsent(enabledFileDropSources: [.openCode])

        #expect(consent.allows(AgentRuntimeEvent(source: .openCode, executionState: .thinking)))
        #expect(!consent.allows(AgentRuntimeEvent(source: .pi, executionState: .thinking)))
        #expect(consent.allows(AgentRuntimeEvent(source: .grok, executionState: .thinking)))
        #expect(consent.allows(AgentRuntimeEvent(source: .claudeCode, executionState: .thinking)))
        #expect(consent.allows(AgentRuntimeEvent(source: .codex, executionState: .thinking)))
        #expect(!consent.allows(AgentRuntimeEvent(source: .unknown, kind: .pi, executionState: .thinking)))
        #expect(consent.allows(AgentRuntimeEvent(source: .unknown, kind: .grok, executionState: .thinking)))
        #expect(consent.allows(AgentRuntimeEvent(source: .unknown, kind: .codex, executionState: .thinking)))
        #expect(consent.allows(AgentRuntimeEvent(source: .unknown, kind: .shell, executionState: .thinking)))
    }

    @Test
    func consentRejectsFileDropProviderEventsWhenNotEnabled() {
        let consent = AgentRuntimeConsent(enabledFileDropSources: [])

        #expect(!consent.allows(AgentRuntimeEvent(source: .openCode, executionState: .thinking)))
        #expect(!consent.allows(AgentRuntimeEvent(source: .unknown, kind: .openCode, executionState: .thinking)))
        #expect(!consent.allows(AgentRuntimeEvent(source: .pi, executionState: .thinking)))
        #expect(!consent.allows(AgentRuntimeEvent(source: .unknown, kind: .pi, executionState: .thinking)))
    }

    @Test
    func consentGatesOpenDocumentEventsForFileDropProviders() {
        let disabled = AgentRuntimeConsent(enabledFileDropSources: [])
        let openCodeEnabled = AgentRuntimeConsent(enabledFileDropSources: [.openCode])
        let event = AgentRuntimeEvent(
            source: .openCode,
            kind: .openCode,
            phase: .openDocument,
            documentPath: "/tmp/notes.md"
        )

        #expect(!disabled.allows(event))
        #expect(openCodeEnabled.allows(event))
        #expect(disabled.allows(AgentRuntimeEvent(
            source: .codex,
            kind: .codex,
            phase: .openDocument,
            documentPath: "/tmp/notes.md"
        )))
    }

    @Test
    func consentAlwaysAllowsClaudeCodexAndGrokEvents() {
        let consent = AgentRuntimeConsent(enabledFileDropSources: [])

        #expect(consent.allows(AgentRuntimeEvent(source: .claudeCode, executionState: .thinking)))
        #expect(consent.allows(AgentRuntimeEvent(source: .codex, executionState: .thinking)))
        #expect(consent.allows(AgentRuntimeEvent(source: .grok, executionState: .thinking)))
        #expect(consent.allows(AgentRuntimeEvent(source: .unknown, kind: .claudeCode, executionState: .thinking)))
        #expect(consent.allows(AgentRuntimeEvent(source: .unknown, kind: .codex, executionState: .thinking)))
        #expect(consent.allows(AgentRuntimeEvent(source: .unknown, kind: .grok, executionState: .thinking)))
    }

    @Test
    func enabledFileDropSourcesComeFromAgentIntegrationConfig() {
        let sources = AgentRuntimeConsent.enabledFileDropSources(from: AgentIntegrationsConfig(
            claudeCode: AgentIntegrationSetup(enabled: true),
            codex: AgentIntegrationSetup(enabled: true),
            openCode: AgentIntegrationSetup(enabled: true),
            pi: AgentIntegrationSetup(enabled: false),
            grok: AgentIntegrationSetup(enabled: true)
        ))

        #expect(sources == [.openCode])
    }
}
