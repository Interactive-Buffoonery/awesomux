import AwesoMuxBridgeProtocol
import Darwin
import Foundation
import SecureFileIO

// MARK: - Failure reasons

/// Why a pane has no readable agent transcript. Every case is a different thing
/// to tell the user and a different thing to do about it, so they stay distinct
/// rather than collapsing into one "no transcript available".
public enum AgentTranscriptUnavailable: Error, Equatable, Sendable {
    /// The pane's agent does not write a JSONL transcript awesoMux can read.
    case unsupportedAgent(AgentKind)
    /// The pane runs over SSH. ADR-0023: the local JSONL agent side channel
    /// cannot cross SSH, so the transcript is on the far host.
    case remoteExecution
    /// A session id was reported but is not the UUID shape both supported
    /// providers use — refuse rather than let it reach a filesystem path.
    case invalidSessionID
    /// Neither a reported session id nor a working directory to fall back on.
    case noSessionIdentity
    /// Nothing on disk matched.
    case notFound
    /// A transcript was found but the secure reader declined to open it.
    case unreadable(SecureFileReadError)
}

// MARK: - Result

/// An open, validated handle to one agent session's JSONL transcript.
///
/// The handle is the product on purpose: locating and opening are one step, so
/// there is no window in which the resolved path can be swapped for another
/// file before someone reopens it.
public struct AgentTranscript: Sendable {
    /// Which of the two resolution paths produced this transcript.
    ///
    /// Surfaced all the way to the document: `AgentTranscriptOpener` turns a
    /// `.workingDirectoryFallback` into a sentence in the rendered transcript's
    /// chrome, because "this is the session you asked for" and "this is the
    /// best guess for your directory" must not look identical on screen.
    public enum Resolution: Equatable, Sendable {
        /// Matched the session id the running agent reported for this pane.
        case reportedSessionID
        /// No id was available; matched the newest transcript recording the
        /// pane's working directory.
        case workingDirectoryFallback
    }

    public let agentKind: AgentKind
    public let sessionID: String
    public let resolution: Resolution
    public let handle: SecureFileReadHandle

    public var resolvedURL: URL { handle.resolvedURL }
}

// MARK: - Importer

/// Turns "the agent session running in this pane" into an open, validated file
/// handle for its on-disk JSONL transcript.
///
/// Resolution and opening are deliberately one operation. A locator that
/// returned a bare `URL` would hand the caller a path to reopen, and the
/// re-open is where a symlink or a replaced file gets substituted for the one
/// that was inspected.
public enum AgentTranscriptImporter {

    // MARK: Provider layout

    /// The two providers whose transcript layout is known. Everything else is
    /// rejected: `AgentRuntimeSource.validatedProviderSessionID` deliberately
    /// exempts Grok from the UUID shape, so a Grok id must never reach a path.
    enum Provider {
        case claudeCode
        case codex

        init?(agentKind: AgentKind) {
            switch agentKind {
            case .claudeCode: self = .claudeCode
            case .codex: self = .codex
            case .openCode, .pi, .grok, .shell: return nil
            }
        }

        /// The subtree of the provider's config home that holds transcripts.
        /// Claude: `projects/<cwd-slug>/<sessionID>.jsonl`.
        /// Codex: `sessions/YYYY/MM/DD/rollout-<ts>-<sessionID>.jsonl`.
        func transcriptRoot(configHome: URL) -> URL {
            switch self {
            case .claudeCode: configHome.appending(path: "projects", directoryHint: .isDirectory)
            case .codex: configHome.appending(path: "sessions", directoryHint: .isDirectory)
            }
        }

        func matchesSessionID(_ sessionID: String, fileName: String) -> Bool {
            switch self {
            case .claudeCode:
                fileName == "\(sessionID).jsonl"
            case .codex:
                fileName.hasPrefix("rollout-") && fileName.hasSuffix("-\(sessionID).jsonl")
            }
        }

        /// Recovers the session id a filename encodes, for the fallback path
        /// where the id is unknown until a file is chosen. Verified: a Codex
        /// rollout's `session_meta.payload.id` matches its filename exactly.
        func sessionID(fromFileName fileName: String) -> String? {
            guard fileName.hasSuffix(".jsonl") else { return nil }
            let stem = String(fileName.dropLast(".jsonl".count))
            let candidate: String
            switch self {
            case .claudeCode:
                candidate = stem
            case .codex:
                // Split on length, not on the last `-`: the timestamp and the
                // UUID both contain hyphens, so `lastIndex(of: "-")` lands
                // inside the UUID's final group.
                let uuidLength = 36
                guard stem.hasPrefix("rollout-"), stem.count > uuidLength,
                    stem[stem.index(stem.endIndex, offsetBy: -(uuidLength + 1))] == "-"
                else { return nil }
                candidate = String(stem.suffix(uuidLength))
            }
            return UUID(uuidString: candidate) == nil ? nil : candidate
        }

        /// Where the working-directory fallback looks, in order.
        ///
        /// Claude names each project's directory after a slug of its working
        /// directory, so the pane's own project is one directory rather than a
        /// scan of the whole corpus. The full root still follows it: the slug
        /// rule is Claude's, not ours, and a session relocated between
        /// worktrees keeps recording its original `cwd` under a different
        /// slug — a miss has to degrade to the old scan, never to `.notFound`.
        ///
        /// Codex records the working directory only *inside* the file
        /// (`session_meta.payload.cwd`), so its `sessions/YYYY/MM/DD/` tree
        /// cannot be scoped by path at all. It is bounded by
        /// `fallbackScanByteBudget` and a cheaper per-candidate probe instead.
        func fallbackSearchRoots(in root: URL, workingDirectory: String) -> [URL] {
            switch self {
            case .claudeCode:
                [
                    root.appending(
                        path: projectSlug(workingDirectory),
                        directoryHint: .isDirectory
                    ),
                    root,
                ]
            case .codex:
                [root]
            }
        }

        /// Claude's project directory name for a working directory. Verified on
        /// a real corpus: `/` and `.` both become `-`.
        ///
        /// Path traversal is structurally impossible rather than filtered —
        /// every separator is one of the replaced characters, so no `..`
        /// sequence can survive as a path component.
        private func projectSlug(_ workingDirectory: String) -> String {
            let standardized = URL(fileURLWithPath: workingDirectory).standardizedFileURL.path
            return String(standardized.map { $0 == "/" || $0 == "." ? "-" : $0 })
        }

        /// Bytes to read when probing a candidate for its recorded working
        /// directory. Claude puts `cwd` on the first `user` record, which a
        /// `file-history-snapshot` can push far in; Codex puts it on the first
        /// `session_meta` line, measured across 800 real rollouts at p50 22 KB,
        /// p99 27 KB, max 44 KB.
        var workingDirectoryProbeByteCount: Int {
            switch self {
            case .claudeCode: headByteCount
            case .codex: 64 * 1024
            }
        }
    }

    // MARK: Tuning

    /// Enough to reach the first conversation record and the recorded working
    /// directory without reading whole multi-megabyte transcripts. Measured on
    /// a real corpus: Claude's first `user`/`assistant` record sits at most
    /// ~21 KB in (a `file-history-snapshot` line precedes it), and the largest
    /// Codex `session_meta` first line observed is ~44 KB.
    ///
    /// ponytail: a fixed head window, not a streaming scan. Raise it if a
    /// provider starts front-loading more metadata; a candidate whose signals
    /// fall past the window degrades to the mtime tie-break, never to a wrong
    /// answer.
    static let headByteCount = 256 * 1024

    /// How much transcript head the working-directory fallback may read before
    /// it gives up.
    ///
    /// A byte budget, not a file count. A count cap was blind to the fact that
    /// the two providers cost different amounts to probe, and — worse — it was
    /// global: the top 200 files *machine-wide* were checked, so with several
    /// active projects the pane's own transcript was never inspected and the
    /// user was told nothing matched. This budget is the same ~51 MB the old
    /// 200-file cap spent on Claude-sized reads, which at Codex's 64 KiB probe
    /// covers a whole 800-rollout corpus (measured: 52 MB, 0.10 s warm) — and
    /// Claude no longer competes for it, because its own project directory is
    /// searched first.
    ///
    /// ponytail: bounded linear scan, on an already-detached task. If a corpus
    /// outgrows it, the next lever is a provider-maintained index, not a
    /// bigger number.
    static let fallbackScanByteBudget = 64 * 1024 * 1024

    // MARK: Entry point

    /// Resolves and opens the transcript for the agent session in one pane.
    ///
    /// - Parameters:
    ///   - agentKind: The pane's agent. Only `.claudeCode` and `.codex` resolve.
    ///   - executionPlan: The pane's durable execution plan. Remote panes are
    ///     rejected; their transcripts live on the far host.
    ///   - configHome: The provider's resolved config home — `CLAUDE_CONFIG_DIR`
    ///     / `CODEX_HOME` or the `config_home` setting, never assumed here. The
    ///     caller resolves it because `AwesoMuxCore` cannot see `AwesoMuxConfig`.
    ///   - reportedSessionID: The session id latched for this pane, if any.
    ///   - workingDirectory: The pane's working directory, used only when no id
    ///     is available.
    ///   - excludedSessionIDs: Session ids already latched to *other* panes.
    ///     Only the working-directory fallback consults them, and it is the one
    ///     signal that separates this pane's session from a neighbour's: two
    ///     panes in one directory both match on `cwd`, and the neighbour is
    ///     newer precisely because its agent is writing right now. A pane whose
    ///     agent has emitted anything since the relaunch has a latched id; that
    ///     id belongs to that pane and to no other.
    public static func open(
        agentKind: AgentKind,
        executionPlan: PaneExecutionPlan,
        configHome: URL,
        reportedSessionID: String?,
        workingDirectory: String?,
        excludedSessionIDs: Set<String> = [],
        effectiveUID: uid_t = geteuid(),
        fileManager: FileManager = .default
    ) -> Result<AgentTranscript, AgentTranscriptUnavailable> {
        guard let provider = Provider(agentKind: agentKind) else {
            return .failure(.unsupportedAgent(agentKind))
        }
        guard case .local = executionPlan else {
            return .failure(.remoteExecution)
        }

        let root = provider.transcriptRoot(configHome: configHome)
        let trimmedSessionID = reportedSessionID?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let trimmedSessionID, !trimmedSessionID.isEmpty {
            // Re-validated here rather than trusted: this is the last point
            // before the value becomes a path component, and the shared gate at
            // `AgentRuntimeSource.validatedProviderSessionID` lets Grok ids
            // through a looser shape.
            guard UUID(uuidString: trimmedSessionID) != nil else {
                return .failure(.invalidSessionID)
            }
            return openBySessionID(
                trimmedSessionID,
                agentKind: agentKind,
                provider: provider,
                root: root,
                effectiveUID: effectiveUID,
                fileManager: fileManager
            )
        }

        // The reattach case (ADR-0011): after a relaunch the agent process is
        // still alive but no hook has fired yet, so nothing has been latched.
        guard let workingDirectory, !workingDirectory.isEmpty else {
            return .failure(.noSessionIdentity)
        }
        return openByWorkingDirectory(
            workingDirectory,
            agentKind: agentKind,
            provider: provider,
            root: root,
            excludedSessionIDs: excludedSessionIDs,
            effectiveUID: effectiveUID,
            fileManager: fileManager
        )
    }

    // MARK: Resolution paths

    private static func openBySessionID(
        _ sessionID: String,
        agentKind: AgentKind,
        provider: Provider,
        root: URL,
        effectiveUID: uid_t,
        fileManager: FileManager
    ) -> Result<AgentTranscript, AgentTranscriptUnavailable> {
        let candidates = transcriptCandidates(in: root, fileManager: fileManager) {
            provider.matchesSessionID(sessionID, fileName: $0)
        }
        guard !candidates.isEmpty else { return .failure(.notFound) }

        func transcript(_ handle: SecureFileReadHandle) -> AgentTranscript {
            AgentTranscript(
                agentKind: agentKind,
                sessionID: sessionID,
                resolution: .reportedSessionID,
                handle: handle
            )
        }

        guard candidates.count > 1 else {
            return openSecurely(candidates[0].url, effectiveUID: effectiveUID)
                .map(transcript)
        }

        // Duplicate basenames are real: the same session id exists as a full
        // transcript under one project directory and as a worktree-relocation
        // sidecar under another. The sidecar carries only `ai-title`,
        // `last-prompt`, `mode` and friends — no conversation at all — so
        // content decides, not the pane's working directory. Tie-breaking on
        // the working directory picks the sidecar whenever the user is in a
        // worktree, which is the common case.
        var best: (handle: SecureFileReadHandle, hasConversation: Bool)?
        var firstFailure: AgentTranscriptUnavailable?
        for candidate in candidates {
            switch openSecurely(candidate.url, effectiveUID: effectiveUID) {
            case let .failure(error):
                firstFailure = firstFailure ?? error
            case let .success(handle):
                let hasConversation = parseHead(
                    head(of: handle, maximumBytes: headByteCount),
                    provider: provider
                ).hasConversationRecord
                if prefers(handle, hasConversation: hasConversation, over: best) {
                    best = (handle, hasConversation)
                }
            }
        }
        guard let best else { return .failure(firstFailure ?? .notFound) }
        return .success(transcript(best.handle))
    }

    /// Ranks two same-id candidates. Conversation beats no conversation; among
    /// candidates that all read as conversationless, SIZE beats modification
    /// date.
    ///
    /// Size, because mtime picks the wrong one. `hasConversationRecord` only
    /// sees the head window, and a session that opens by reading large files
    /// buries its first turn behind `file-history-snapshot` records, so a real
    /// transcript can read as conversationless. A relocation stub is rewritten
    /// on every relocation, making it routinely the *newer* file — and at ~1.4 KB
    /// against ~14 MB, never the bigger one. Losing that tie-break rendered "no
    /// conversation turns" over a session that had plenty.
    private static func prefers(
        _ handle: SecureFileReadHandle,
        hasConversation: Bool,
        over best: (handle: SecureFileReadHandle, hasConversation: Bool)?
    ) -> Bool {
        guard let best else { return true }
        guard hasConversation == best.hasConversation else { return hasConversation }
        // Candidates arrive newest-first, so among conversation-bearing
        // transcripts the incumbent is already the newest.
        return hasConversation ? false : handle.size > best.handle.size
    }

    private static func openByWorkingDirectory(
        _ workingDirectory: String,
        agentKind: AgentKind,
        provider: Provider,
        root: URL,
        excludedSessionIDs: Set<String>,
        effectiveUID: uid_t,
        fileManager: FileManager
    ) -> Result<AgentTranscript, AgentTranscriptUnavailable> {
        let wanted = normalizedPath(workingDirectory)
        let probeBytes = provider.workingDirectoryProbeByteCount
        var remainingBudget = fallbackScanByteBudget
        var visited: Set<URL> = []

        // The pane's own project directory first, then everything. The second
        // pass re-enumerates the first, which `visited` absorbs — enumeration is
        // free next to the reads the budget actually counts.
        for scanRoot in provider.fallbackSearchRoots(in: root, workingDirectory: workingDirectory) {
            let candidates = transcriptCandidates(in: scanRoot, fileManager: fileManager) {
                $0.hasSuffix(".jsonl")
            }
            for candidate in candidates {
                guard remainingBudget > 0 else { return .failure(.notFound) }
                guard visited.insert(candidate.url).inserted else { continue }
                guard
                    let sessionID = provider.sessionID(
                        fromFileName: candidate.url.lastPathComponent
                    ),
                    !excludedSessionIDs.contains(sessionID)
                else { continue }
                guard
                    case let .success(handle) = openSecurely(
                        candidate.url,
                        effectiveUID: effectiveUID
                    )
                else { continue }
                let probe = head(of: handle, maximumBytes: probeBytes)
                remainingBudget -= probe.count
                guard let recorded = parseHead(probe, provider: provider).recordedWorkingDirectory,
                    normalizedPath(recorded) == wanted
                else { continue }
                return .success(
                    AgentTranscript(
                        agentKind: agentKind,
                        sessionID: sessionID,
                        resolution: .workingDirectoryFallback,
                        handle: handle
                    )
                )
            }
        }
        return .failure(.notFound)
    }

    // MARK: Candidate discovery

    /// Every entry under `root` whose filename passes `matches`, newest
    /// modification first.
    ///
    /// Deliberately no regular-file or symlink filter here: `SecureFileReader`
    /// is the single authority on what may be opened, and filtering first would
    /// turn its `notRegularFile` / symlink refusals into a silent `notFound`.
    private static func transcriptCandidates(
        in root: URL,
        fileManager: FileManager,
        matches: (String) -> Bool
    ) -> [(url: URL, modified: Date)] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard
            let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
        else { return [] }

        var found: [(url: URL, modified: Date)] = []
        for case let url as URL in enumerator {
            guard matches(url.lastPathComponent) else { continue }
            let modified = try? url.resourceValues(forKeys: Set(keys)).contentModificationDate
            found.append((url, modified ?? .distantPast))
        }
        return found.sorted { $0.modified > $1.modified }
    }

    // MARK: Secure open

    private static func openSecurely(
        _ url: URL,
        effectiveUID: uid_t
    ) -> Result<SecureFileReadHandle, AgentTranscriptUnavailable> {
        do {
            // `.rejectFinalComponent`, unlike `DocumentLoader`'s default: a user
            // picks the documents they open, but these paths are discovered by
            // scanning a directory the agent owns, so a symlink planted there is
            // an anomaly to refuse rather than a redirection to honour.
            return .success(
                try SecureFileReader.open(
                    at: url,
                    effectiveUID: effectiveUID,
                    symlinkPolicy: .rejectFinalComponent
                )
            )
        } catch {
            return .failure(.unreadable(error))
        }
    }

    /// The opening bytes of an already-validated handle, for the two callers
    /// that need a signal out of them.
    ///
    /// Separate from the open because most opens do not want it: resolving a
    /// unique session id, and `sessionLogExists`'s liveness probe, both discard
    /// it, and that probe runs on a button press.
    ///
    /// `readPrefix`, not `read`: transcripts routinely run to tens of megabytes,
    /// and `read` treats anything past the cap as `.tooLarge`. A read that fails
    /// yields no signals rather than an error — the handle is already validated,
    /// so the caller's ranking simply has nothing to go on.
    private static func head(
        of handle: SecureFileReadHandle,
        maximumBytes: Int
    ) -> Data {
        (try? handle.readPrefix(maximumBytes: maximumBytes)) ?? Data()
    }

    // MARK: Head parsing

    struct TranscriptHead: Equatable {
        var recordedWorkingDirectory: String?
        var hasConversationRecord = false
    }

    /// Reads the two signals resolution needs out of a transcript's opening
    /// bytes. Lines that fail to parse are skipped, which also covers the
    /// truncated last line of a head read.
    static func parseHead(_ data: Data, provider: Provider) -> TranscriptHead {
        var head = TranscriptHead()
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)),
                let record = object as? [String: Any],
                let type = record["type"] as? String
            else { continue }

            switch provider {
            case .claudeCode:
                if type == "user" || type == "assistant" {
                    head.hasConversationRecord = true
                }
                if head.recordedWorkingDirectory == nil, let cwd = record["cwd"] as? String {
                    head.recordedWorkingDirectory = cwd
                }
            case .codex:
                if type == "response_item" || type == "event_msg" {
                    head.hasConversationRecord = true
                }
                if head.recordedWorkingDirectory == nil, type == "session_meta",
                    let payload = record["payload"] as? [String: Any],
                    let cwd = payload["cwd"] as? String
                {
                    head.recordedWorkingDirectory = cwd
                }
            }

            if head.hasConversationRecord, head.recordedWorkingDirectory != nil { break }
        }
        return head
    }

    /// Both sides of a working-directory comparison go through the same
    /// normalization because a recorded `/tmp/x` and a pane's `/private/tmp/x`
    /// are the same directory. `resolvingSymlinksInPath` degrades to plain
    /// standardization when the path no longer exists.
    private static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}
