import AwesoMuxBridgeProtocol
import Foundation
import SecureFileIO

/// Metadata only. Listing never retains prompt text or renders cache artifacts.
public struct AgentProjectTranscriptEntry: Identifiable, Sendable {
    public let identity: AgentTranscriptIdentity
    public let modified: Date
    public var id: AgentTranscriptIdentity { identity }

    let sourceURL: URL
    let fileIdentity: SecureFileIdentity
    let size: UInt64
    let containsConversation: Bool
}

public struct AgentProjectTranscriptListing: Sendable {
    public let entries: [AgentProjectTranscriptEntry]
    public let isIncomplete: Bool
}

/// An explicitly requested project lookup, separate from exact-session Resume.
public enum AgentProjectTranscripts {
    public struct Root: Sendable {
        public let agentKind: AgentKind
        public let configHome: URL

        public init(agentKind: AgentKind, configHome: URL) {
            self.agentKind = agentKind
            self.configHome = configHome
        }
    }

    public static let maximumResults = 100
    static let maximumEntriesPerProvider = 8_192
    static let maximumProbesPerProvider = 1_024
    static let headBytes = 64 * 1024

    public static func list(projectDirectory: URL, roots: [Root]) -> AgentProjectTranscriptListing {
        guard projectDirectory.isFileURL,
            let directory = WorkingDirectoryValidator.validatedReportedDirectory(projectDirectory.path)
        else { return AgentProjectTranscriptListing(entries: [], isIncomplete: true) }
        let project = URL(fileURLWithPath: directory).resolvingSymlinksInPath().standardizedFileURL
        var best: [AgentTranscriptIdentity: AgentProjectTranscriptEntry] = [:]
        var incomplete = false
        // Fixed provider allowlist bounds both traversal and aggregate bytes,
        // even if a caller accidentally supplies repeated roots.
        for kind in [AgentKind.claudeCode, .codex] {
            guard !Task.isCancelled else { break }
            guard let root = roots.first(where: { $0.agentKind == kind }) else { continue }
            let scan = scan(project: project, root: root)
            incomplete = incomplete || scan.isIncomplete
            for entry in scan.entries {
                if preferred(entry, over: best[entry.identity]) {
                    best[entry.identity] = entry
                }
            }
        }
        let sorted = best.values.sorted {
            if $0.modified != $1.modified { return $0.modified > $1.modified }
            if $0.identity.agentKind != $1.identity.agentKind {
                return $0.identity.agentKind.rawValue < $1.identity.agentKind.rawValue
            }
            return $0.identity.sessionID < $1.identity.sessionID
        }
        return AgentProjectTranscriptListing(
            entries: Array(sorted.prefix(maximumResults)),
            isIncomplete: incomplete || sorted.count > maximumResults
        )
    }

    /// Revalidate the listed inode and metadata, rather than rediscovering an
    /// identically named sidecar belonging to another project.
    public static func open(
        _ entry: AgentProjectTranscriptEntry,
        projectDirectory: URL
    ) -> Result<AgentTranscript, AgentTranscriptUnavailable> {
        guard !Task.isCancelled, projectDirectory.isFileURL,
            WorkingDirectoryValidator.validatedReportedDirectory(projectDirectory.path) != nil
        else { return .failure(.notFound) }
        do {
            let handle = try SecureFileReader.open(
                at: entry.sourceURL, symlinkPolicy: .rejectFinalComponent
            )
            var incomplete = false
            guard handle.identity == entry.fileIdentity,
                let current = metadata(
                    handle: handle,
                    kind: entry.identity.agentKind,
                    project: projectDirectory.standardizedFileURL,
                    modified: entry.modified,
                    incomplete: &incomplete
                ), current.identity == entry.identity
            else { return .failure(.notFound) }
            return .success(
                AgentTranscript(
                    agentKind: entry.identity.agentKind,
                    sessionID: entry.identity.sessionID,
                    handle: handle
                )
            )
        } catch let error {
            return .failure(.unreadable(error))
        }
    }

    /// Initial mount, recovery and restore all retain the browser's admission
    /// scope; an exact-session importer cannot enforce this narrower contract.
    public static func open(
        identity: AgentTranscriptIdentity,
        configHome: URL
    ) -> Result<AgentTranscript, AgentTranscriptUnavailable> {
        guard let directory = identity.projectDirectory else { return .failure(.notFound) }
        let project = URL(fileURLWithPath: directory, isDirectory: true)
        let listing = scan(
            project: project,
            root: Root(agentKind: identity.agentKind, configHome: configHome),
            sessionID: identity.sessionID
        )
        var best: AgentProjectTranscriptEntry?
        for entry in listing.entries where preferred(entry, over: best) {
            best = entry
        }
        guard let best else {
            return .failure(listing.isIncomplete ? .searchLimitReached : .notFound)
        }
        return open(best, projectDirectory: project)
    }

    /// The inode pin alone cannot detect same-inode metadata edits.
    public static func reopen(
        _ prior: AgentTranscript,
        projectDirectory: String
    ) -> Result<AgentTranscript, AgentTranscriptUnavailable> {
        switch AgentTranscriptImporter.reopen(prior) {
        case .failure(let reason): return .failure(reason)
        case .success(let transcript):
            var incomplete = false
            guard
                let current = metadata(
                    handle: transcript.handle, kind: transcript.agentKind,
                    project: URL(fileURLWithPath: projectDirectory, isDirectory: true),
                    modified: .distantPast, incomplete: &incomplete
                ), current.identity.agentKind == transcript.agentKind,
                current.identity.sessionID == transcript.sessionID
            else { return .failure(.notFound) }
            return .success(transcript)
        }
    }

    private static func scan(project: URL, root: Root, sessionID: String? = nil) -> AgentProjectTranscriptListing {
        let manager = FileManager.default
        let providerRoot: URL
        switch root.agentKind {
        case .claudeCode:
            let slug = String(
                project.path.unicodeScalars.map { scalar -> Character in
                    switch scalar.value {
                    case 48...57, 65...90, 97...122: Character(String(scalar))
                    default: "-"
                    }
                })
            providerRoot = root.configHome.appending(path: "projects").appending(path: slug)
        case .codex:
            providerRoot = root.configHome.appending(path: "sessions")
        default:
            return AgentProjectTranscriptListing(entries: [], isIncomplete: false)
        }
        if (try? providerRoot.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
            return AgentProjectTranscriptListing(entries: [], isIncomplete: true)
        }
        let canonicalRoot = providerRoot.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: canonicalRoot.path, isDirectory: &isDirectory) else {
            return AgentProjectTranscriptListing(entries: [], isIncomplete: false)
        }
        guard isDirectory.boolValue else {
            return AgentProjectTranscriptListing(entries: [], isIncomplete: true)
        }
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey,
        ]
        var incomplete = false
        guard
            let enumerator = manager.enumerator(
                at: canonicalRoot,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in
                    incomplete = true
                    return false
                }
            )
        else { return AgentProjectTranscriptListing(entries: [], isIncomplete: true) }
        var entries: [AgentProjectTranscriptEntry] = []
        var inspected = 0
        var probes = 0
        for case let url as URL in enumerator {
            guard !Task.isCancelled else { break }
            inspected += 1
            guard inspected <= maximumEntriesPerProvider else {
                incomplete = true
                break
            }
            guard let values = try? url.resourceValues(forKeys: keys) else {
                incomplete = true
                continue
            }
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            if values.isDirectory == true {
                // Claude is one project directory, Codex is YYYY/MM/DD only.
                let component = url.lastPathComponent
                let dateDirectory =
                    root.agentKind == .codex && enumerator.level <= 3
                    && component.count == (enumerator.level == 1 ? 4 : 2)
                    && component.utf8.allSatisfy { (48...57).contains($0) }
                if !dateDirectory { enumerator.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true, url.pathExtension == "jsonl",
                root.agentKind != .codex || url.lastPathComponent.hasPrefix("rollout-")
            else { continue }
            if let sessionID,
                !AgentTranscriptImporter.matchesTranscriptFileName(
                    agentKind: root.agentKind, sessionID: sessionID, fileName: url.lastPathComponent
                )
            {
                continue
            }
            guard probes < maximumProbesPerProvider else {
                incomplete = true
                break
            }
            probes += 1
            do {
                let handle = try SecureFileReader.open(at: url, symlinkPolicy: .rejectFinalComponent)
                guard handle.resolvedURL.path.hasPrefix(canonicalRoot.path + "/") else {
                    incomplete = true
                    continue
                }
                if let entry = metadata(
                    handle: handle,
                    kind: root.agentKind,
                    project: project,
                    modified: values.contentModificationDate ?? .distantPast,
                    incomplete: &incomplete
                ) {
                    entries.append(entry)
                }
            } catch {
                incomplete = true
            }
        }
        return AgentProjectTranscriptListing(entries: entries, isIncomplete: incomplete)
    }

    private static func metadata(
        handle: SecureFileReadHandle,
        kind: AgentKind,
        project: URL,
        modified: Date,
        incomplete: inout Bool
    ) -> AgentProjectTranscriptEntry? {
        guard let data = try? handle.readPrefix(maximumBytes: headBytes) else {
            incomplete = true
            return nil
        }
        var sessionID: String?
        var cwd: String?
        var conversation = false
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard !Task.isCancelled else { return nil }
            guard let record = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any]
            else { continue }
            let type = record["type"] as? String
            switch kind {
            case .codex:
                if type == "session_meta" {
                    guard sessionID == nil, let payload = record["payload"] as? [String: Any],
                        payload["parent_thread_id"] == nil || payload["parent_thread_id"] is NSNull,
                        (payload["source"] as? [String: Any])?["subagent"] == nil
                    else { return nil }
                    sessionID = payload["id"] as? String
                    cwd = payload["cwd"] as? String
                }
                conversation = conversation || AgentTranscriptRenderer.isCodexConversationRecord(record)
            case .claudeCode:
                // Inline children belong in the render, not in parent provenance.
                guard (record["isSidechain"] as? Bool) != true else { continue }
                if let reported = record["sessionId"] as? String {
                    guard sessionID == nil || sessionID == reported else { return nil }
                    sessionID = reported
                }
                if let reported = record["cwd"] as? String {
                    guard cwd == nil || cwd == reported else { return nil }
                    cwd = reported
                }
                conversation = conversation || type == "user" || type == "assistant"
            default:
                return nil
            }
        }
        guard let cwd, cwd.hasPrefix("/"), cwd.utf8.count <= 4096 else {
            incomplete = true
            return nil
        }
        guard URL(fileURLWithPath: cwd).resolvingSymlinksInPath().standardizedFileURL == project else {
            return nil
        }
        if kind == .claudeCode, sessionID == nil {
            sessionID = handle.resolvedURL.deletingPathExtension().lastPathComponent
        }
        guard let sessionID,
            let identity = AgentTranscriptIdentity(agentKind: kind, sessionID: sessionID),
            AgentTranscriptImporter.matchesTranscriptFileName(
                agentKind: kind, sessionID: identity.sessionID,
                fileName: handle.resolvedURL.lastPathComponent
            )
        else { return nil }
        return AgentProjectTranscriptEntry(
            identity: identity, modified: modified,
            sourceURL: handle.resolvedURL, fileIdentity: handle.identity,
            size: handle.size, containsConversation: conversation
        )
    }

    private static func preferred(
        _ candidate: AgentProjectTranscriptEntry, over current: AgentProjectTranscriptEntry?
    ) -> Bool {
        guard let current else { return true }
        if candidate.containsConversation != current.containsConversation {
            return candidate.containsConversation
        }
        if candidate.size != current.size { return candidate.size > current.size }
        if candidate.modified != current.modified { return candidate.modified > current.modified }
        return candidate.sourceURL.path < current.sourceURL.path
    }
}
