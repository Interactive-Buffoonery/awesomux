import AwesoMuxBridgeProtocol
import AwesoMuxConfig
import AwesoMuxCore
import Foundation
import Testing

@testable import awesoMux

@Suite("Agent transcript pane inputs")
struct AgentTranscriptPaneInputsTests {
    private static let home = URL(fileURLWithPath: "/Users/tester")

    private func attempts(
        for kind: AgentKind,
        integrations: AgentIntegrationsConfig = AgentIntegrationsConfig()
    ) -> [(kind: AgentKind, configHome: URL)] {
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
        #expect(attempts(for: .openCode).map(\.kind) == [.openCode])
    }

    @Test("a shell pane never guesses which provider owned a session")
    func shellPaneDoesNotSweepProviders() {
        #expect(attempts(for: .shell).isEmpty)
    }

    @Test("a live pane identity wins over a last-ended one")
    func liveIdentityWinsOverLastEnded() throws {
        let lastEnded = try #require(
            AgentTranscriptIdentity(agentKind: .codex, sessionID: "9a8b7c6d-5e4f-4321-9876-543210fedcba")
        )
        let live = try #require(
            AgentTranscriptIdentity(
                agentKind: .claudeCode,
                sessionID: "3f2b1c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d"
            )
        )

        #expect(
            AgentTranscriptPaneInputs.lookupIdentity(
                paneKind: .claudeCode,
                liveSessionID: live.sessionID,
                lastEnded: lastEnded
            ) == live
        )
    }

    @Test("a shell pane uses the last-ended identity instead of sweeping")
    func shellPaneUsesLastEndedIdentity() throws {
        let lastEnded = try #require(
            AgentTranscriptIdentity(
                agentKind: .claudeCode,
                sessionID: "3f2b1c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d"
            )
        )

        #expect(
            AgentTranscriptPaneInputs.lookupIdentity(
                paneKind: .shell,
                liveSessionID: nil,
                lastEnded: lastEnded
            ) == lastEnded
        )
        #expect(
            attempts(for: lastEnded.agentKind).map(\.kind) == [.claudeCode],
            "lookup names the ended provider; resolution still does not sweep"
        )
    }

    @Test("a shell pane with no last-ended identity has nothing to open")
    func shellPaneWithoutLastEndedHasNoIdentity() {
        #expect(
            AgentTranscriptPaneInputs.lookupIdentity(
                paneKind: .shell,
                liveSessionID: nil,
                lastEnded: nil
            ) == nil
        )
    }

    @Test("a live pane without a session id does not fall back to the previous session")
    func livePaneDoesNotInheritLastEndedIdentity() throws {
        let lastEnded = try #require(
            AgentTranscriptIdentity(
                agentKind: .claudeCode,
                sessionID: "3f2b1c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d"
            )
        )

        #expect(
            AgentTranscriptPaneInputs.lookupIdentity(
                paneKind: .claudeCode,
                liveSessionID: nil,
                lastEnded: lastEnded
            ) == nil
        )
    }

    @Test("Pi resolves only its own provider root")
    func additionalProvidersResolveTheirOwnRoots() {
        #expect(attempts(for: .pi).first?.configHome.path == "/Users/tester/.pi/agent")
        #expect(
            attempts(for: .openCode).first?.configHome.path
                == "/Users/tester/.local/share/opencode"
        )
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

    @Test("a live supported pane without an identity reports the missing identity")
    func liveSupportedPaneNeedsIdentity() {
        #expect(
            AgentTranscriptPaneInputs.emptyLookupReason(paneKind: .openCode, lastEndedKind: nil)
                == .noSessionIdentity
        )
    }

    @Test("a live unsupported pane names itself rather than claiming an unknown session")
    func liveUnsupportedPaneNamesTheAgent() {
        #expect(
            AgentTranscriptPaneInputs.emptyLookupReason(paneKind: .grok, lastEndedKind: nil)
                == .unsupportedAgent(.grok)
        )
    }

    @Test("an ended supported OpenCode pane reports a missing identity")
    func endedOpenCodePaneNeedsIdentity() {
        #expect(
            AgentTranscriptPaneInputs.emptyLookupReason(
                paneKind: .shell,
                lastEndedKind: .openCode
            ) == .noSessionIdentity
        )
    }

    @Test("an ended unsupported pane still names itself after becoming a shell")
    func endedUnsupportedPaneKeepsItsName() {
        #expect(
            AgentTranscriptPaneInputs.emptyLookupReason(
                paneKind: .shell,
                lastEndedKind: .grok
            ) == .unsupportedAgent(.grok)
        )
    }

    @Test("an ended Claude pane without identity reports a missing session, not an unsupported agent")
    func endedSupportedPaneWithoutIdentityIsUnknownSession() {
        #expect(
            AgentTranscriptPaneInputs.emptyLookupReason(
                paneKind: .shell,
                lastEndedKind: .claudeCode
            ) == .noSessionIdentity
        )
        #expect(
            AgentTranscriptPaneInputs.emptyLookupReason(paneKind: .shell, lastEndedKind: nil)
                == .noSessionIdentity
        )
    }
}
