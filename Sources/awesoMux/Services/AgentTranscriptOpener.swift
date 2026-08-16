import AwesoMuxBridgeProtocol
import AwesoMuxConfig
import AwesoMuxCore
import Foundation
import SecureFileIO

// MARK: - Result types

/// A rendered transcript ready to open in a document tab.
struct OpenedAgentTranscript: Equatable, Sendable {
    /// The cache file to hand `openDocumentPane`. Regenerable storage — the
    /// identity, not this, is the tab's provenance.
    let fileURL: URL
    let identity: AgentTranscriptIdentity
}

/// Everything that can stop a transcript reaching the screen.
///
/// `AgentTranscriptUnavailable` covers resolving and reading; the one failure
/// that happens after it — writing the rendered Markdown into awesoMux's own
/// owner-only cache — has nothing to do with the provider, and folding it into
/// `.unreadable` would tell the user their transcript is corrupt when their
/// Application Support directory is.
enum AgentTranscriptOpenFailure: Error, Equatable, Sendable {
    case unavailable(AgentTranscriptUnavailable)
    case cacheWriteFailed
    case providerExecutableNotFound
    case providerExportFailed
    case invalidProviderExport
}

// MARK: - Opener

/// Resolves, renders, and stores the transcript for one pane's agent session.
///
/// Deliberately not `@MainActor`: rendering reads and converts up to 32 MiB
/// (measured at 0.34 s for a 27 MB Claude session), so callers run this on a
/// detached task and only touch the store with the result.
enum AgentTranscriptOpener {

    static func openProviderTranscript(
        agentKind: AgentKind,
        executionPlan: PaneExecutionPlan,
        configHome: URL,
        setup: AgentIntegrationSetup,
        reportedSessionID: String?,
        store: AgentTranscriptStore = AgentTranscriptStore(),
        exportOpenCode:
            @Sendable (String, AgentIntegrationSetup) async -> Result<
                Data, OpenCodeTranscriptExporter.ExportError
            > = { sessionID, setup in
                await OpenCodeTranscriptExporter.export(sessionID: sessionID, setup: setup)
            }
    ) async -> Result<OpenedAgentTranscript, AgentTranscriptOpenFailure> {
        guard agentKind == .openCode else {
            return open(
                agentKind: agentKind,
                executionPlan: executionPlan,
                configHome: configHome,
                reportedSessionID: reportedSessionID,
                store: store
            )
        }
        guard case .local = executionPlan else {
            return .failure(.unavailable(.remoteExecution))
        }
        guard let reportedSessionID else {
            return .failure(.unavailable(.noSessionIdentity))
        }
        guard
            let identity = AgentTranscriptIdentity(
                agentKind: .openCode,
                sessionID: reportedSessionID
            )
        else {
            return .failure(.unavailable(.invalidSessionID))
        }
        let exported = await exportOpenCode(identity.sessionID, setup)
        let data: Data
        switch exported {
        case .success(let value): data = value
        case .failure(.executableNotFound): return .failure(.providerExecutableNotFound)
        case .failure(.commandFailed): return .failure(.providerExportFailed)
        }
        guard
            let markdown = AgentTranscriptRenderer.renderOpenCodeExport(
                data,
                sessionID: identity.sessionID,
                chrome: localizedChrome(agentKind: .openCode)
            )
        else {
            return .failure(.invalidProviderExport)
        }
        guard
            let fileURL = store.write(
                markdown,
                agentKind: .openCode,
                sessionID: identity.sessionID
            )
        else {
            return .failure(.cacheWriteFailed)
        }
        return .success(OpenedAgentTranscript(fileURL: fileURL, identity: identity))
    }

    static func open(
        agentKind: AgentKind,
        executionPlan: PaneExecutionPlan,
        configHome: URL,
        reportedSessionID: String?,
        store: AgentTranscriptStore = AgentTranscriptStore()
    ) -> Result<OpenedAgentTranscript, AgentTranscriptOpenFailure> {
        let opened = AgentTranscriptImporter.open(
            agentKind: agentKind,
            executionPlan: executionPlan,
            configHome: configHome,
            reportedSessionID: reportedSessionID
        )
        let transcript: AgentTranscript
        switch opened {
        case .success(let resolved): transcript = resolved
        case .failure(let reason): return .failure(.unavailable(reason))
        }

        // The importer's allowlist and the identity's are the same list, so
        // this cannot fail for a transcript the importer just returned.
        guard let identity = AgentTranscriptIdentity(transcript) else {
            return .failure(.unavailable(.unsupportedAgent(transcript.agentKind)))
        }

        let markdown: String
        switch AgentTranscriptRenderer.render(
            transcript,
            chrome: localizedChrome(agentKind: transcript.agentKind)
        ) {
        case .success(let text): markdown = text
        case .failure(let reason): return .failure(.unavailable(reason))
        }

        // Keyed on the validated provider session id so the cache slot agrees
        // with the immutable identity stored on the tab.
        guard
            let fileURL = store.write(
                markdown,
                agentKind: transcript.agentKind,
                sessionID: transcript.sessionID
            )
        else {
            return .failure(.cacheWriteFailed)
        }
        return .success(
            OpenedAgentTranscript(
                fileURL: fileURL,
                identity: identity
            )
        )
    }

    /// Whether the provider's own log for `identity` is still on disk.
    ///
    /// The liveness probe Resume needs, and deliberately not a process check:
    /// `claude --resume` and `codex resume` both work against a session that has
    /// long since exited, and fail only once its log is gone.
    ///
    /// Resolves by the STORED session id with no working-directory fallback. A
    /// fallback here would match some *other* session in the same directory and
    /// report this one as resumable.
    static func sessionLogExists(
        identity: AgentTranscriptIdentity,
        executionPlan: PaneExecutionPlan,
        configHome: URL
    ) -> Bool {
        switch AgentTranscriptImporter.open(
            agentKind: identity.agentKind,
            executionPlan: executionPlan,
            configHome: configHome,
            reportedSessionID: identity.sessionID
        ) {
        case .success: return true
        case .failure: return false
        }
    }

    static func sessionLogExists(
        identity: AgentTranscriptIdentity,
        executionPlan: PaneExecutionPlan,
        configHome: URL,
        setup: AgentIntegrationSetup
    ) async -> Bool {
        guard case .local = executionPlan else { return false }
        if identity.agentKind == .openCode {
            guard
                case .success = await OpenCodeTranscriptExporter.export(
                    sessionID: identity.sessionID,
                    setup: setup
                )
            else { return false }
            return true
        }
        return sessionLogExists(
            identity: identity,
            executionPlan: executionPlan,
            configHome: configHome
        )
    }

    // MARK: Localized document chrome

    /// The app layer owns localization (ADR-0014), so the words awesoMux writes
    /// into the transcript are composed here and passed down. This keeps every
    /// sentence in the document in one file and keeps the renderer a pure
    /// function of its arguments — not because `AwesoMuxCore` is unable to
    /// localize (it resolves against `Bundle.main` like any other module, and
    /// the catalog is extracted from all of `Sources`).
    static func localizedChrome(agentKind: AgentKind) -> AgentTranscriptRenderer.Chrome {
        AgentTranscriptRenderer.Chrome(
            title: String(
                localized: "\(agentKind.displayName) transcript",
                comment: "Heading of a rendered agent transcript document, naming the provider"
            ),
            sessionLabel: String(
                localized: "Session",
                comment: "Label before the provider session id in a rendered agent transcript"
            ),
            truncationNotice: String(
                localized:
                    "Earlier turns are omitted. This document holds the most recent history that fits.",
                comment: "Notice in a rendered agent transcript when older turns exceeded the size budget"
            ),
            emptyWindowNotice: String(
                localized: "No conversation turns could be rendered from the most recent history.",
                comment: "Notice in a rendered agent transcript when the recent history held nothing renderable"
            ),
            oversizeRecordTitle: String(
                localized: "omitted",
                comment: "Heading marking one agent transcript record that was too large to display"
            ),
            oversizeRecordNotice: { size in
                String(
                    localized: "One record of \(size) was too large to display.",
                    comment:
                        "Notice naming the formatted byte size of one agent transcript record that was skipped"
                )
            },
            oversizeFragmentNotice: { size in
                String(
                    localized: "One record larger than \(size) could not be displayed.",
                    comment:
                        "Notice for an agent transcript record so large that only its tail fell inside the window, so its size is a lower bound"
                )
            }
        )
    }

    // MARK: Failure copy

    /// A distinct sentence per failure. "No transcript available" for all seven
    /// outcomes is a support ticket: three of them are things the user can fix
    /// right now, and each names a different fix.
    static func unavailableDescription(for failure: AgentTranscriptOpenFailure) -> String {
        switch failure {
        case .cacheWriteFailed:
            return String(
                localized: "awesoMux couldn't save the rendered transcript to its cache.",
                comment: "Transcript failure when writing the rendered Markdown to the app cache fails"
            )
        case .providerExecutableNotFound:
            return String(
                localized: "awesoMux couldn't find the OpenCode executable. Check its binary path in Settings.",
                comment: "Transcript failure when the OpenCode executable cannot be resolved"
            )
        case .providerExportFailed:
            return String(
                localized: "OpenCode couldn't export this session.",
                comment: "Transcript failure when the OpenCode export command fails"
            )
        case .invalidProviderExport:
            return String(
                localized: "OpenCode exported a session format awesoMux couldn't read.",
                comment: "Transcript failure when the OpenCode export JSON is invalid or unsupported"
            )
        case .unavailable(let reason):
            return unavailableDescription(for: reason)
        }
    }

    static func unavailableDescription(for reason: AgentTranscriptUnavailable) -> String {
        switch reason {
        case .unsupportedAgent(let kind):
            return String(
                localized:
                    "\(kind.displayName) doesn't write a session log awesoMux can read. Transcripts are available for Claude Code, Codex, OpenCode, and Pi.",
                comment: "Transcript failure when the pane's agent has no readable session log"
            )
        case .remoteExecution:
            return String(
                localized:
                    "This pane runs over SSH, and its session log stays on the remote host. Open the transcript from a local pane.",
                comment: "Transcript failure when the pane runs over SSH"
            )
        case .invalidSessionID:
            return String(
                localized:
                    "This pane reported a session id awesoMux won't use to look up a file. Start a new agent session and try again.",
                comment: "Transcript failure when the reported provider session id failed validation"
            )
        case .noSessionIdentity:
            return String(
                localized:
                    "awesoMux doesn't know which session this pane is running yet. Send the agent a prompt, then try again.",
                comment: "Transcript failure when no provider session id has been reported"
            )
        case .notFound:
            return String(
                localized:
                    "awesoMux searched the agent's session folder and found nothing recorded for this pane's session. If you've moved the agent's Config home, check it in Settings.",
                comment: "Transcript failure when nothing on disk matched the session"
            )
        case .searchLimitReached:
            return String(
                localized:
                    "awesoMux stopped searching because the agent's session folder exceeded its safety limit.",
                comment: "Transcript failure when bounded session-log discovery reaches its safety limit"
            )
        case .unreadable:
            return String(
                localized:
                    "awesoMux found this session's log but refused to read it. It may be a symlink, or owned by another user.",
                comment: "Transcript failure when the secure file reader declined to open the resolved session log"
            )
        }
    }
}
