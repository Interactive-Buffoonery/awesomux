import AwesoMuxBridgeProtocol
import Foundation
import Testing

@testable import AwesoMuxCore

private let claudeSession = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"

private func localTerminal() -> TerminalPane {
    TerminalPane(title: "zsh", workingDirectory: "/tmp", executionPlan: .local)
}

// MARK: - Command composition

@Suite struct AgentTranscriptResumeCommandTests {
    @Test(arguments: [AgentKind.claudeCode, .codex, .pi])
    func stagedCommandUsesValidatedIdentity(kind: AgentKind) throws {
        for hostile in [
            "'; echo injected #", "$(echo injected)", "`echo injected`", "../../other/session.jsonl", "/tmp/session with spaces.jsonl",
        ] {
            #expect(AgentTranscriptIdentity(agentKind: kind, sessionID: hostile) == nil)
        }
        let stored = try #require(AgentTranscriptIdentity(agentKind: kind, sessionID: claudeSession))
        let prefix: String =
            switch kind {
            case .claudeCode: "claude --resume"
            case .codex: "codex resume"
            default: "pi --session"
            }
        let command = try #require(AgentTranscriptResumePolicy.command(for: stored))
        #expect(command == "\(prefix) '\(claudeSession)'")
        #expect(RichInputStaging.stagedPayload(command) == command)
    }
}

// MARK: - Eligibility

@Suite struct AgentTranscriptResumeVerdictTests {

    /// The whole reason Resume cannot reuse the Send gate, inverted: Send needs
    /// a live agent, Resume needs the agent GONE. Denied loudly and by name —
    /// a resume command staged at Claude's prompt is pasted as chat.
    @Test(arguments: [
        ("claude", AgentTranscriptResumeUnavailableReason.agentRunning(.claudeCode) as AgentTranscriptResumeUnavailableReason?),
        ("codex", .agentRunning(.codex)),
        ("muse", .agentRunning(.generic)),
        ("2.1.214", .agentRunning(.claudeCode)),
        ("nvim", .foregroundBusy), ("ssh", .foregroundBusy),
        ("less", .foregroundBusy), ("python3", .foregroundBusy),
        ("-zsh", nil),
    ])
    func foregroundEligibility(command: String, denial: AgentTranscriptResumeUnavailableReason?) {
        let terminal = localTerminal()
        #expect(
            AgentTranscriptResumePolicy.verdict(
                target: .available(terminal), observedForegroundCommand: command
            ) == (denial.map { .unavailable($0) } ?? .eligible(terminal.id)))
    }

    @Test func failsClosedWithoutForegroundEvidence() {
        for comm in [nil, ""] {
            #expect(
                AgentTranscriptResumePolicy.verdict(
                    target: .available(localTerminal()),
                    observedForegroundCommand: comm
                ) == .unavailable(.foregroundUnverified)
            )
        }
    }

    /// End to end through the real layout resolver, not a hand-built
    /// resolution: a transcript tab beside an SSH pane must deny, because the
    /// provider log lives on the far host (ADR-0023).
    @Test func deniedForARemotePaneThroughTheRealLayoutResolver() throws {
        let target = try #require(RemoteTarget(user: "alice", host: "remote.example"))
        let terminal = TerminalPane(
            title: "remote",
            workingDirectory: "/home/alice",
            executionPlan: .ssh(SSHExecution(target: target))
        )
        let tab = DocumentPane(
            fileURL: URL(fileURLWithPath: "/tmp/cache/abc.transcript.md"),
            title: "Claude Code Transcript",
            associatedTerminalPaneID: terminal.id,
            agentTranscriptIdentity: AgentTranscriptIdentity(agentKind: .claudeCode, sessionID: claudeSession)
        )
        let layout = TerminalPaneLayout.split(
            TerminalSplit(
                orientation: .vertical,
                first: .pane(terminal),
                second: .documentGroup(DocumentGroup(tabs: [tab], selectedTabID: tab.id))
            ))

        #expect(
            AgentTranscriptResumePolicy.verdict(
                target: layout.documentNudgeTarget(for: tab.id),
                observedForegroundCommand: "zsh"
            ) == .unavailable(.requiresLocalTerminal)
        )
    }
}
