import AwesoMuxBridgeProtocol
import AwesoMuxConfig
import AwesoMuxCore
import Foundation

/// Stages a transcript document's `--resume` command into the terminal it was
/// rendered beside.
///
/// Shared by the send bar's Resume button and the app-level Resume command
/// rather than duplicated. The button sets `refusesFirstResponder = true` for
/// the same focus-safety reason as the tab pill's close X (INT-562), so the
/// menu/palette command is the only route Full Keyboard Access and switch
/// control have — and a second copy of the eligibility → probe → recheck ladder
/// is a second place for the recheck to be forgotten.
@MainActor
enum AgentTranscriptResumeStaging {

    enum Outcome: Equatable {
        case staged
        /// A staging attempt for this same document is still probing. Not a
        /// denial: nothing is wrong, the first attempt simply owns the send.
        case alreadyStaging
        case unavailable(AgentTranscriptResumeUnavailableReason)
    }

    /// Separates the staged command from whatever is already at the cursor.
    ///
    /// `sendText` writes at the cursor and cannot see the shell's line buffer,
    /// so a half-typed `git stat` used to compose `git statclaude --resume …` —
    /// one plausible-looking command in a monospace terminal. A newline is not
    /// available (it would submit the half-typed line) and neither is a
    /// line-kill: staged text goes through libghostty's bracketed paste, where
    /// a `Ctrl-U` byte is inserted literally rather than interpreted, which is
    /// also why `RichInputStaging` strips C0 in the first place.
    ///
    /// Note: a leading space, unconditionally. It costs a shell configured
    /// with `HIST_IGNORE_SPACE` the history entry for the resume line. Revisit
    /// if that is reported, or if a line-clear primitive that survives
    /// bracketed paste ever exists.
    static let cursorSeparator = " "

    /// Documents with an attempt in flight. Keyed per document rather than
    /// held on either view, because the two surfaces stage the same payload
    /// into the same terminal: a double click and a click-plus-menu race are
    /// the same bug, and one guard in the shared path covers both.
    private static var inFlight: Set<DocumentPane.ID> = []

    static func isStaging(_ documentID: DocumentPane.ID) -> Bool {
        inFlight.contains(documentID)
    }

    /// - Parameters:
    ///   - layout: The layout snapshot the click was made against. Used only to
    ///     resolve the document's terminal association, which the awaited probe
    ///     below cannot change.
    ///   - foregroundComm: A LIVE probe, called twice on purpose. See the
    ///     recheck below.
    ///   - sessionLogExists: Injected so tests can drive the probe's timing;
    ///     the default runs the real directory walk off the main actor.
    static func stage(
        identity: AgentTranscriptIdentity,
        documentID: DocumentPane.ID,
        layout: TerminalPaneLayout,
        integrations: AgentIntegrationsConfig,
        foregroundComm: @MainActor (TerminalPane.ID) -> String?,
        sendText: @MainActor (String, TerminalPane.ID) -> Bool,
        sessionLogExists:
            @Sendable (
                AgentTranscriptIdentity, PaneExecutionPlan, URL, AgentIntegrationSetup
            ) async -> Bool = detachedSessionLogExists
    ) async -> Outcome {
        guard let command = AgentTranscriptResumePolicy.command(for: identity) else {
            return .unavailable(.noResumeSyntax(identity.agentKind))
        }
        guard !inFlight.contains(documentID) else { return .alreadyStaging }

        let target = layout.documentNudgeTarget(for: documentID)
        func verdict() -> AgentTranscriptResumeVerdict {
            AgentTranscriptResumePolicy.verdict(
                target: target,
                observedForegroundCommand: {
                    guard case .available(let resolved) = target else { return nil }
                    return foregroundComm(resolved.id)
                }()
            )
        }

        // Cheap denial first, so an obviously-ineligible click never pays for
        // the directory walk below.
        let preflight = verdict()
        guard case .eligible = preflight, case .available(let resolved) = target else {
            guard case .unavailable(let reason) = preflight else {
                return .unavailable(.terminalUnavailable)
            }
            return .unavailable(reason)
        }
        let setup = AgentConfigHome.setup(for: identity.agentKind, in: integrations)
        guard
            let configHome = AgentConfigHome.url(
                for: identity.agentKind,
                setup: setup
            )
        else {
            return .unavailable(.transcriptMissing)
        }

        inFlight.insert(documentID)
        defer { inFlight.remove(documentID) }

        // The identity is durable; the session's liveness is not. Off the main
        // actor because resolving a transcript enumerates the provider root.
        guard await sessionLogExists(identity, resolved.executionPlan, configHome, setup) else {
            return .unavailable(.transcriptMissing)
        }

        // The recheck the detached probe makes necessary. Eligibility was
        // decided before a filesystem walk that can take as long as a cold
        // directory enumeration, and an agent can be launched inside that
        // window. Staging a shell command at a live agent's prompt pastes it as
        // CHAT — pressing Return sends it as a message instead of running it —
        // so the verdict has to be re-earned immediately before the send, not
        // inherited from before the wait.
        let recheck = verdict()
        guard case .eligible = recheck else {
            guard case .unavailable(let reason) = recheck else {
                return .unavailable(.terminalUnavailable)
            }
            return .unavailable(reason)
        }

        let payload = RichInputStaging.stagedPayload(command)
        guard !payload.isEmpty, sendText(cursorSeparator + payload, resolved.id) else {
            return .unavailable(.terminalUnavailable)
        }
        return .staged
    }

    private static let detachedSessionLogExists:
        @Sendable (
            AgentTranscriptIdentity, PaneExecutionPlan, URL, AgentIntegrationSetup
        ) async -> Bool = { identity, executionPlan, configHome, _ in
            AgentTranscriptOpener.sessionLogExists(
                identity: identity,
                executionPlan: executionPlan,
                configHome: configHome
            )
        }
}
