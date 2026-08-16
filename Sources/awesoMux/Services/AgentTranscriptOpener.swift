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
    /// How the session was identified. The document says so in its own words
    /// (see `localizedChrome`); this is the same fact in a form the app layer
    /// can act on — a fallback-resolved id is a directory guess, and staging
    /// `--resume` against a guess deserves a confirmation.
    let resolution: AgentTranscript.Resolution
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
}

// MARK: - Opener

/// Resolves, renders, and stores the transcript for one pane's agent session.
///
/// Deliberately not `@MainActor`: rendering reads and converts up to 32 MiB
/// (measured at 0.34 s for a 27 MB Claude session), so callers run this on a
/// detached task and only touch the store with the result.
enum AgentTranscriptOpener {

    /// Resolves a pane that still names its own provider.
    static func open(
        agentKind: AgentKind,
        executionPlan: PaneExecutionPlan,
        configHome: URL,
        reportedSessionID: String?,
        workingDirectory: String?,
        excludedSessionIDs: Set<String> = [],
        store: AgentTranscriptStore = AgentTranscriptStore()
    ) -> Result<OpenedAgentTranscript, AgentTranscriptOpenFailure> {
        open(
            attempts: [(kind: agentKind, configHome: configHome)],
            executionPlan: executionPlan,
            reportedSessionID: reportedSessionID,
            workingDirectory: workingDirectory,
            excludedSessionIDs: excludedSessionIDs,
            store: store
        )
    }

    /// Resolves every attempt and renders the most recently modified match.
    ///
    /// The sweep exists for a `.shell` pane, where `sessionEnd` has already
    /// taken the provider name with it and both providers have to be tried.
    /// Stopping at the first attempt that resolves would decide that question
    /// by `AgentKind` declaration order: for a maintainer who runs both CLIs in
    /// one repository, "Claude ran here once" would beat "Codex ran here thirty
    /// seconds ago", and Resume would then stage `claude --resume` into a
    /// terminal that had been running Codex. Modification date is the only
    /// evidence available about which one the user just exited.
    ///
    /// Cheap enough to do unconditionally: each attempt is the resolution the
    /// first-hit sweep already performed, on the same detached task, and only
    /// the winner is read, rendered, and written.
    static func open(
        attempts: [(kind: AgentKind, configHome: URL)],
        executionPlan: PaneExecutionPlan,
        reportedSessionID: String?,
        workingDirectory: String?,
        excludedSessionIDs: Set<String> = [],
        store: AgentTranscriptStore = AgentTranscriptStore()
    ) -> Result<OpenedAgentTranscript, AgentTranscriptOpenFailure> {
        var best: (transcript: AgentTranscript, modified: Date)?
        var firstFailure: AgentTranscriptUnavailable?
        for attempt in attempts {
            switch AgentTranscriptImporter.open(
                agentKind: attempt.kind,
                executionPlan: executionPlan,
                configHome: attempt.configHome,
                reportedSessionID: reportedSessionID,
                workingDirectory: workingDirectory,
                excludedSessionIDs: excludedSessionIDs
            ) {
            case .failure(let reason):
                firstFailure = firstFailure ?? reason
            case .success(let resolved):
                let modified =
                    (try? resolved.resolvedURL.resourceValues(
                        forKeys: [.contentModificationDateKey]
                    ).contentModificationDate) ?? .distantPast
                if best.map({ modified > $0.modified }) ?? true {
                    best = (resolved, modified)
                }
            }
        }
        guard let best else {
            return .failure(.unavailable(firstFailure ?? .notFound))
        }
        return render(best.transcript, store: store)
    }

    private static func render(
        _ transcript: AgentTranscript,
        store: AgentTranscriptStore
    ) -> Result<OpenedAgentTranscript, AgentTranscriptOpenFailure> {
        // The importer's allowlist and the identity's are the same list, so
        // this cannot fail for a transcript the importer just returned.
        guard let identity = AgentTranscriptIdentity(transcript) else {
            return .failure(.unavailable(.unsupportedAgent(transcript.agentKind)))
        }

        let markdown: String
        switch AgentTranscriptRenderer.render(
            transcript,
            chrome: localizedChrome(
                agentKind: transcript.agentKind,
                resolution: transcript.resolution
            )
        ) {
        case .success(let text): markdown = text
        case .failure(let reason): return .failure(.unavailable(reason))
        }

        // Keyed on the RESOLVED session id, not the reported one: the
        // working-directory fallback discovers the id from the file it matched,
        // and the cache slot has to agree with the identity stored on the tab.
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
                identity: identity,
                resolution: transcript.resolution
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
            reportedSessionID: identity.sessionID,
            workingDirectory: nil
        ) {
        case .success: return true
        case .failure: return false
        }
    }

    // MARK: Localized document chrome

    /// The app layer owns localization (ADR-0014), so the words awesoMux writes
    /// into the transcript are composed here and passed down. This keeps every
    /// sentence in the document in one file and keeps the renderer a pure
    /// function of its arguments — not because `AwesoMuxCore` is unable to
    /// localize (it resolves against `Bundle.main` like any other module, and
    /// the catalog is extracted from all of `Sources`).
    static func localizedChrome(
        agentKind: AgentKind,
        resolution: AgentTranscript.Resolution = .reportedSessionID
    ) -> AgentTranscriptRenderer.Chrome {
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
            },
            provenanceNotice: provenanceNotice(for: resolution, agentKind: agentKind)
        )
    }

    /// The document's own admission that it may be the wrong session.
    ///
    /// The working-directory fallback fires exactly when awesoMux has no id for
    /// the pane — after a relaunch, with the agent still alive, or right after
    /// the agent exited and took the pane's provider name with it. It matches a
    /// directory, and a directory can hold several sessions, including one live
    /// in the pane next door. Nil for a reported id, where there is nothing to
    /// qualify.
    ///
    /// It names the agent because the pane may no longer be able to: a `.shell`
    /// pane sweeps both providers, so the guess spans agents as well as
    /// sessions, and "a different session" would understate it.
    private static func provenanceNotice(
        for resolution: AgentTranscript.Resolution,
        agentKind: AgentKind
    ) -> String? {
        switch resolution {
        case .reportedSessionID:
            return nil
        case .workingDirectoryFallback:
            return String(
                localized:
                    "This pane hasn't reported a session yet, so awesoMux matched the most recent \(agentKind.displayName) transcript recorded for its working directory. It may belong to a different session, or to a different agent than the one you were running here.",
                comment:
                    "Notice in a rendered agent transcript when the session was matched by working directory instead of a reported session id"
            )
        }
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
        case .unavailable(let reason):
            return unavailableDescription(for: reason)
        }
    }

    static func unavailableDescription(for reason: AgentTranscriptUnavailable) -> String {
        switch reason {
        case .unsupportedAgent(let kind):
            return String(
                localized:
                    "\(kind.displayName) doesn't write a session log awesoMux can read. Transcripts are available for Claude Code and Codex.",
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
                comment: "Transcript failure when no session id has been reported and there is no working directory to fall back on"
            )
        case .notFound:
            // Names what was searched, not a guess at why it was empty. The
            // usual cause is that no session log records this pane at all;
            // a relocated Config home is the rarer one, so it comes second.
            return String(
                localized:
                    "awesoMux searched the agent's session folder and found nothing recorded for this pane's session or its working directory. If you've moved the agent's Config home, check it in Settings.",
                comment: "Transcript failure when nothing on disk matched the session"
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
