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
