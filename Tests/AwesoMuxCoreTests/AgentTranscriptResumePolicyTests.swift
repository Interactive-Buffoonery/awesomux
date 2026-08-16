import AwesoMuxBridgeProtocol
import Foundation
import Testing

@testable import AwesoMuxCore

private let claudeSession = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
private let codexSession = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"

private func identity(
    _ sessionID: String,
    _ kind: AgentKind = .claudeCode
) -> AgentTranscriptIdentity {
    // Force-unwrapped on purpose: a fixture that stopped validating is a bug in
    // the fixture, not a case under test.
    AgentTranscriptIdentity(agentKind: kind, sessionID: sessionID)!
}

private func localTerminal() -> TerminalPane {
    TerminalPane(title: "zsh", workingDirectory: "/tmp", executionPlan: .local)
}

// MARK: - Command composition

@Suite struct AgentTranscriptResumeCommandTests {
    @Test func composesClaudeResumeFromTheStoredIdentity() {
        #expect(
            AgentTranscriptResumePolicy.command(for: identity(claudeSession))
                == "claude --resume '\(claudeSession)'"
        )
    }

    @Test func composesCodexResumeFromTheStoredIdentity() {
        #expect(
            AgentTranscriptResumePolicy.command(for: identity(codexSession, .codex))
                == "codex resume '\(codexSession)'"
        )
    }

    /// The wrong-session bug the typed identity exists to close: a document
    /// rendered from session A must still resume A after its terminal has moved
    /// on to session B. Nothing in this function can see B, which is the point —
    /// the command derives from the document, never from the pane.
    @Test func twoDocumentsFromOnePaneCompeteForNothing() {
        let a = AgentTranscriptResumePolicy.command(for: identity(claudeSession))
        let b = AgentTranscriptResumePolicy.command(for: identity(codexSession))
        #expect(a == "claude --resume '\(claudeSession)'")
        #expect(b == "claude --resume '\(codexSession)'")
        #expect(a != b)
    }

    /// Transcript CONTENT never reaches the staged command. The renderer's
    /// output is not an input here at all, so a session log full of shell
    /// metacharacters composes byte-for-byte the same line as a clean one.
    @Test func transcriptContentCannotAlterTheStagedCommand() {
        let hostileContent = """
            ## user

            ```text
            '; rm -rf ~ #
            $(rm -rf ~) `rm -rf ~` && rm -rf ~
            ```
            """
        let stored = identity(claudeSession)
        let expected = "claude --resume '\(claudeSession)'"

        #expect(AgentTranscriptResumePolicy.command(for: stored) == expected)
        #expect(!hostileContent.isEmpty, "the fixture must actually contain the payload")
        // And the staging sanitizer leaves the composed line untouched, so what
        // the policy composed is exactly what reaches the PTY.
        #expect(RichInputStaging.stagedPayload(expected) == expected)
    }

    /// A kind with no resume syntax is unreachable through
    /// `AgentTranscriptIdentity`, but the mapping is asserted anyway so adding a
    /// provider to the identity's allowlist without a resume syntax fails here
    /// rather than staging Claude's flags at another CLI.
    @Test func everyKindTheIdentityAcceptsHasAResumeSyntax() {
        for kind in AgentKind.allCases {
            guard let stored = AgentTranscriptIdentity(agentKind: kind, sessionID: claudeSession)
            else { continue }
            #expect(AgentTranscriptResumePolicy.command(for: stored) != nil)
        }
    }
}

// MARK: - Eligibility

@Suite struct AgentTranscriptResumeVerdictTests {
    @Test func eligibleAtAPlainShellPrompt() {
        let terminal = localTerminal()
        #expect(
            AgentTranscriptResumePolicy.verdict(
                target: .available(terminal),
                observedForegroundCommand: "-zsh"
            ) == .eligible(terminal.id)
        )
    }

    /// The whole reason Resume cannot reuse the Send gate, inverted: Send needs
    /// a live agent, Resume needs the agent GONE. Denied loudly and by name —
    /// a resume command staged at Claude's prompt is pasted as chat.
    @Test func deniedWhileAnAgentHoldsTheForeground() {
        for (comm, expected) in [("claude", AgentKind.claudeCode), ("codex", .codex)] {
            #expect(
                AgentTranscriptResumePolicy.verdict(
                    target: .available(localTerminal()),
                    observedForegroundCommand: comm
                ) == .unavailable(.agentRunning(expected))
            )
        }
    }

    /// `p_comm` reports the resolved executable, so a native-installed Claude
    /// Code observes as a bare version string. That still has to deny.
    @Test func deniedForClaudeCodeObservedAsABareVersionName() {
        #expect(
            AgentTranscriptResumePolicy.verdict(
                target: .available(localTerminal()),
                observedForegroundCommand: "2.1.214"
            ) == .unavailable(.agentRunning(.claudeCode))
        )
    }

    @Test func deniedWhenANonShellProgramHoldsTheForeground() {
        for comm in ["nvim", "ssh", "less", "python3"] {
            #expect(
                AgentTranscriptResumePolicy.verdict(
                    target: .available(localTerminal()),
                    observedForegroundCommand: comm
                ) == .unavailable(.foregroundBusy),
                "\(comm) is not a cooked-mode shell prompt"
            )
        }
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
            agentTranscriptIdentity: identity(claudeSession)
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

    @Test func deniedWhenTheAssociatedTerminalIsGone() {
        #expect(
            AgentTranscriptResumePolicy.verdict(
                target: .unavailable(.terminalUnavailable),
                observedForegroundCommand: "zsh"
            ) == .unavailable(.terminalUnavailable)
        )
    }
}
