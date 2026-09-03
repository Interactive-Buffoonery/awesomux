import AwesoMuxBridgeProtocol
import Foundation

// MARK: - Reasons

/// Why the Resume control on a transcript tab cannot stage its command.
///
/// Distinct from `DocumentNudgeUnavailableReason` on purpose. The two policies
/// have *opposite* preconditions: Send to Agent requires a verified live agent
/// waiting at its prompt, while Resume exists precisely because that agent has
/// exited. Sharing one reason vocabulary would invite sharing the gate, and
/// `AgentPromptGate` would deny Resume in exactly the situation Resume is for.
public enum AgentTranscriptResumeUnavailableReason: Hashable, Sendable {
    /// No terminal is associated with this document any more.
    case terminalUnavailable
    /// The associated terminal runs over SSH. The provider CLI and its session
    /// log live on the far host, so a locally-staged resume would target a
    /// session the remote agent never had.
    case requiresLocalTerminal
    /// No foreground-process evidence for the target terminal. Fails closed.
    case foregroundUnverified
    /// An agent is live in the target terminal. Staging a shell command into an
    /// agent's prompt pastes it as CHAT — pressing Return would send it as a
    /// message rather than run it — so this denies loudly and names the exit.
    case agentRunning(AgentKind)
    /// Something other than a plain shell holds the foreground: a TUI, an SSH
    /// client, a long-running command. Staged bytes reach a raw-mode program
    /// immediately, so only a cooked-mode shell prompt is eligible.
    case foregroundBusy
    /// The provider's own session log is gone, so `--resume` would fail. Probed
    /// at click time, never per render: resolving a transcript is a directory
    /// walk, and the send bar re-renders on every foreground-state change.
    case transcriptMissing
    /// `command(for:)` has no resume syntax for this provider. Surfaced up
    /// front when a transcript tab's stored identity names a provider awesoMux
    /// can render but not resume (OpenCode today).
    case noResumeSyntax(AgentKind)
    /// The command ran with no transcript tab selected — from the menu, the
    /// palette, or the chord.
    ///
    /// This reason exists so the command can stay *enabled*. Disabling it
    /// looked tidier and cost more than it saved: a disabled SwiftUI menu
    /// command does not consume its key equivalent, so ⌃⌘R fell through to
    /// libghostty, which echoed a CSI-u sequence into the user's shell
    /// (observed live: a bare `4;5u` at the prompt). The palette had the
    /// mirror-image problem — it listed the command and running it did
    /// nothing at all.
    ///
    /// Staying enabled and naming the cause matches what the Resume button
    /// already does for every other denial, and it keeps the chord owned by
    /// the app instead of leaking it to the terminal.
    case noTranscriptSelected
}

public enum AgentTranscriptResumeVerdict: Hashable, Sendable {
    case eligible(TerminalPane.ID)
    case unavailable(AgentTranscriptResumeUnavailableReason)
}

// MARK: - Policy

/// Eligibility and command composition for resuming the agent session a
/// transcript document was rendered from.
public enum AgentTranscriptResumePolicy {

    /// The shell command that resumes `identity`'s session.
    ///
    /// Built from exactly two inputs: the provider kind, and the session id
    /// stored on the *document*. Never from transcript content, and never from
    /// whatever session the adjacent pane is running now — document A must
    /// resume session A even after the pane has moved on to session B.
    ///
    /// The id is a validated provider session id by construction (`AgentTranscriptIdentity`),
    /// so quoting cannot be load-bearing today. It is applied anyway: the value
    /// originates on a same-UID-writable event file and, on the bridge path, on
    /// a remote host, and a single gate deleted three refactors from now should
    /// not be the only thing standing between that and a shell.
    ///
    /// - Returns: `nil` for OpenCode, whose identity and transcript are supported
    ///   but which does not provide resume syntax. Other kinds without resume
    ///   syntax are rejected when their provider lacks transcript support.
    public static func command(for identity: AgentTranscriptIdentity) -> String? {
        let sessionID = NudgeComposer.shellSingleQuoted(identity.sessionID)
        switch identity.agentKind {
        case .claudeCode:
            // Note: the bare command name, not the integration's configured
            // `binary_path`. The line is staged and never submitted, so a user
            // whose CLI is off `PATH` can edit it before pressing Return. Thread
            // the configured path through if that turns out to be a real
            // annoyance rather than a theoretical one.
            return "claude --resume \(sessionID)"
        case .codex:
            return "codex resume \(sessionID)"
        case .pi:
            return "pi --session \(sessionID)"
        case .openCode, .grok, .shell, .generic:
            return nil
        }
    }

    /// Whether the Resume control may stage into its target right now.
    ///
    /// - Parameters:
    ///   - target: The document's nudge-target resolution. Reused for the
    ///     association walk and the local-execution gate only — the verified
    ///     agent gate that `DocumentPaneSendBar.resolveNudgeTarget` layers on
    ///     top must NOT be applied here.
    ///   - observedForegroundCommand: The target terminal's live foreground
    ///     process name (`p_comm`), or nil when no evidence is available.
    public static func verdict(
        target: DocumentNudgeTargetResolution,
        observedForegroundCommand: String?,
        identity: AgentTranscriptIdentity? = nil
    ) -> AgentTranscriptResumeVerdict {
        if let identity, command(for: identity) == nil {
            return .unavailable(.noResumeSyntax(identity.agentKind))
        }
        let pane: TerminalPane
        switch target {
        case .available(let resolved):
            pane = resolved
        case .unavailable(.requiresLocalTerminal):
            return .unavailable(.requiresLocalTerminal)
        case .unavailable:
            // Every other reason `documentNudgeTarget` can produce means the
            // association no longer resolves to a usable terminal. The
            // agent-prompt reasons cannot occur: this reads the layout-level
            // resolution, which never consults `AgentPromptGate`.
            return .unavailable(.terminalUnavailable)
        }

        guard let observedForegroundCommand, !observedForegroundCommand.isEmpty else {
            return .unavailable(.foregroundUnverified)
        }
        if let running = liveAgentKind(inForeground: observedForegroundCommand) {
            return .unavailable(.agentRunning(running))
        }
        guard ShellRecognition.isRecognizedShell(observedForegroundCommand) else {
            return .unavailable(.foregroundBusy)
        }
        return .eligible(pane.id)
    }

    /// The provider whose binary is in the foreground, if any.
    ///
    /// Reuses `AgentPromptGate`'s name matching rather than a second name list:
    /// the gate's job is deciding a name IS a given provider, which is exactly
    /// the question here, only with the answer used to deny instead of allow.
    /// Kinds the matcher never accepts (`.grok`, `.shell`) fall through to the
    /// shell check and are denied there.
    static func liveAgentKind(inForeground command: String) -> AgentKind? {
        AgentKind.allCases.first {
            AgentPromptGate.foregroundCommandMatches($0, observedCommand: command)
        }
    }
}
