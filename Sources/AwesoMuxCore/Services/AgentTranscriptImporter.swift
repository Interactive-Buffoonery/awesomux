import AwesoMuxBridgeProtocol
import Darwin
import Foundation
import SecureFileIO

public enum AgentTranscriptUnavailable: Error, Equatable, Sendable {
    case unsupportedAgent(AgentKind)
    case remoteExecution
    case invalidSessionID
    case noSessionIdentity
    case notFound
    case searchLimitReached
    case unreadable(SecureFileReadError)
}

/// An exact provider session resolved to an already-open, validated transcript.
/// Keeping the descriptor avoids a path handoff between discovery and reading.
public struct AgentTranscript: Sendable {
    public let agentKind: AgentKind
    public let sessionID: String
    public let handle: SecureFileReadHandle

    public var resolvedURL: URL { handle.resolvedURL }
}

/// Resolves an exact provider session without guessing from a working directory.
public enum AgentTranscriptImporter {
    enum Provider: CaseIterable {
        case claudeCode
        case codex
        case pi

        init?(agentKind: AgentKind) {
            switch agentKind {
            case .claudeCode: self = .claudeCode
            case .codex: self = .codex
            case .pi: self = .pi
            case .openCode, .grok, .shell: return nil
            }
        }

        var source: AgentRuntimeSource {
            switch self {
            case .claudeCode: .claudeCode
            case .codex: .codex
            case .pi: .pi
            }
        }

        func transcriptRoot(configHome: URL) -> URL {
            switch self {
            case .claudeCode:
                configHome.appending(path: "projects", directoryHint: .isDirectory)
            case .codex:
                configHome.appending(path: "sessions", directoryHint: .isDirectory)
            case .pi:
                configHome.appending(path: "sessions", directoryHint: .isDirectory)
            }
        }

        func matches(sessionID: String, fileName: String) -> Bool {
            switch self {
            case .claudeCode:
                return fileName == "\(sessionID).jsonl"
            case .codex:
                return fileName.hasPrefix("rollout-") && fileName.hasSuffix("-\(sessionID).jsonl")
            case .pi:
                // Pi names files `{timestamp}_{sessionID}.jsonl`. A suffix-only
                // match would treat `…_my_foo.jsonl` as session `foo`. The
                // timestamp prefix uses hyphens, so rejecting any `_` in the
                // prefix keeps the session id exact.
                if fileName == "\(sessionID).jsonl" { return true }
                let suffix = "_\(sessionID).jsonl"
                guard fileName.hasSuffix(suffix) else { return false }
                let prefix = fileName.dropLast(suffix.count)
                return !prefix.isEmpty && !prefix.contains("_")
            }
        }

        func containsConversation(in data: Data) -> Bool {
            for line in data.split(separator: UInt8(ascii: "\n")) {
                guard let object = try? JSONSerialization.jsonObject(with: Data(line)),
                    let record = object as? [String: Any],
                    let type = record["type"] as? String
                else { continue }

                switch self {
                case .claudeCode where type == "user" || type == "assistant": return true
                case .codex where type == "response_item" || type == "event_msg": return true
                case .pi where type == "message" || type == "custom_message": return true
                default: continue
                }
            }
            return false
        }
    }

    /// Bounds metadata traversal independently of transcript size. Exact-name
    /// lookup still has to walk date/project directories because neither CLI
    /// publishes an index, but a malformed tree must not make a menu command
    /// scan forever.
    static let maximumEntriesInspected = 8_192
    static let maximumMatchingCandidates = 32
    static let headByteCount = 256 * 1024

    /// The provider-owned root whose directory events can make an exact
    /// session discovery succeed after a source disappears.
    public static func transcriptSearchRoot(agentKind: AgentKind, configHome: URL) -> URL? {
        Provider(agentKind: agentKind)?.transcriptRoot(configHome: configHome)
    }

    /// Whether a provider-owned filename belongs to this exact session.
    /// Recovery watchers use the same identity rule as discovery so unrelated
    /// sessions cannot spend this session's bounded recovery budget.
    public static func matchesTranscriptFileName(
        agentKind: AgentKind,
        sessionID: String,
        fileName: String
    ) -> Bool {
        Provider(agentKind: agentKind)?.matches(sessionID: sessionID, fileName: fileName) ?? false
    }

    public static func open(
        agentKind: AgentKind,
        executionPlan: PaneExecutionPlan,
        configHome: URL,
        reportedSessionID: String?,
        effectiveUID: uid_t = geteuid(),
        fileManager: FileManager = .default
    ) -> Result<AgentTranscript, AgentTranscriptUnavailable> {
        guard let provider = Provider(agentKind: agentKind) else {
            return .failure(.unsupportedAgent(agentKind))
        }
        guard case .local = executionPlan else {
            return .failure(.remoteExecution)
        }
        guard let reportedSessionID else {
            return .failure(.noSessionIdentity)
        }
        guard let sessionID = provider.source.validatedProviderSessionID(reportedSessionID) else {
            return .failure(.invalidSessionID)
        }

        let search = transcriptCandidates(
            in: provider.transcriptRoot(configHome: configHome),
            sessionID: sessionID,
            provider: provider,
            fileManager: fileManager
        )
        guard !search.candidates.isEmpty else {
            return .failure(search.reachedLimit ? .searchLimitReached : .notFound)
        }
        guard !search.reachedMatchLimit else {
            return .failure(.searchLimitReached)
        }

        var best: OpenCandidate?
        var firstFailure: AgentTranscriptUnavailable?
        for candidate in search.candidates {
            do {
                let handle = try SecureFileReader.open(
                    at: candidate.url,
                    effectiveUID: effectiveUID,
                    symlinkPolicy: .rejectFinalComponent
                )
                let head = (try? handle.readPrefix(maximumBytes: headByteCount)) ?? Data()
                let opened = OpenCandidate(
                    handle: handle,
                    containsConversation: provider.containsConversation(in: head),
                    modified: candidate.modified
                )
                if opened.isPreferred(over: best) {
                    best = opened
                }
            } catch let error {
                firstFailure = firstFailure ?? .unreadable(error)
            }
        }

        guard let best else {
            return .failure(firstFailure ?? .notFound)
        }
        return .success(
            AgentTranscript(agentKind: agentKind, sessionID: sessionID, handle: best.handle)
        )
    }

    /// Re-opens the transcript a previous discovery already resolved, so a
    /// caller can see bytes the agent appended since.
    ///
    /// A fresh open is the only way to see them. `SecureFileReadHandle` anchors
    /// every read to the length it validated at open, so the descriptor already
    /// on `prior` can never grow. Re-opening is also the point: it re-runs the
    /// owner, regular-file, and symlink checks against whatever inode the path
    /// names *now*, which is what makes a repeating read a repeating ingress
    /// rather than one validation trusted forever.
    ///
    /// Takes the typed `AgentTranscript` rather than a free `(identity, URL)`
    /// pair on purpose: a pair lets a caller bind a validated session id to an
    /// unrelated file that happens to pass the same checks, which is exactly
    /// the identity/content decoupling the secure ingress exists to prevent.
    /// Threading the value keeps the pairing honest, because the only way to
    /// obtain an `AgentTranscript` is a successful discovery here.
    ///
    /// The type alone is not enough, though: a path is not an inode. Re-opening
    /// resolves whatever the path names *now*, so carrying `prior.sessionID`
    /// forward unconditionally would stamp a validated session id onto a
    /// replacement file — the same decoupling, through a different door. The
    /// device/inode pair is therefore compared against the one discovery bound
    /// the id to, and a mismatch is reported as `.notFound` so the caller
    /// re-runs discovery and re-establishes the binding properly rather than
    /// reading a stranger's bytes under this session's name.
    public static func reopen(
        _ prior: AgentTranscript,
        effectiveUID: uid_t = geteuid()
    ) -> Result<AgentTranscript, AgentTranscriptUnavailable> {
        do {
            let handle = try SecureFileReader.open(
                at: prior.resolvedURL,
                effectiveUID: effectiveUID,
                symlinkPolicy: .rejectFinalComponent
            )
            guard handle.identity == prior.handle.identity else {
                return .failure(.notFound)
            }
            return .success(
                AgentTranscript(
                    agentKind: prior.agentKind,
                    sessionID: prior.sessionID,
                    handle: handle
                )
            )
        } catch let error {
            return .failure(.unreadable(error))
        }
    }

    struct CandidateSearch {
        var candidates: [(url: URL, modified: Date)]
        var reachedLimit: Bool
        var reachedMatchLimit: Bool
    }

    static func transcriptCandidates(
        in root: URL,
        sessionID: String,
        provider: Provider,
        fileManager: FileManager,
        maximumEntries: Int = maximumEntriesInspected,
        maximumMatches: Int = maximumMatchingCandidates
    ) -> CandidateSearch {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        guard
            let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
        else {
            return CandidateSearch(
                candidates: [], reachedLimit: false, reachedMatchLimit: false
            )
        }

        var inspected = 0
        var candidates: [(url: URL, modified: Date)] = []
        for case let url as URL in enumerator {
            inspected += 1
            guard inspected <= maximumEntries else {
                return CandidateSearch(
                    candidates: candidates,
                    reachedLimit: true,
                    reachedMatchLimit: false
                )
            }
            guard provider.matches(sessionID: sessionID, fileName: url.lastPathComponent) else {
                continue
            }
            guard candidates.count < maximumMatches else {
                return CandidateSearch(
                    candidates: candidates,
                    reachedLimit: false,
                    reachedMatchLimit: true
                )
            }
            let modified = try? url.resourceValues(forKeys: keys).contentModificationDate
            candidates.append((url, modified ?? .distantPast))
        }
        return CandidateSearch(
            candidates: candidates,
            reachedLimit: false,
            reachedMatchLimit: false
        )
    }

    private struct OpenCandidate {
        var handle: SecureFileReadHandle
        var containsConversation: Bool
        var modified: Date

        func isPreferred(over current: OpenCandidate?) -> Bool {
            guard let current else { return true }
            if containsConversation != current.containsConversation {
                return containsConversation
            }
            if containsConversation {
                return modified > current.modified
            }
            return handle.size > current.handle.size
        }
    }
}
