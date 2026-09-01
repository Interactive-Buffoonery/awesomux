import AwesoMuxBridgeProtocol
import Foundation

/// The owner-only cache holding agent transcripts rendered to Markdown, so a
/// document pane has a real `.md` file to open.
///
/// Naming and the transcript-specific identity key live here; the write, prune,
/// retention, and locking mechanics are `GeneratedDocumentCache`, which the
/// branch-changes cache shares. Read that type for the retention argument and
/// the plaintext-exposure posture this inherits.
struct AgentTranscriptStore: Sendable {
    static let directoryName = "agent-transcripts"

    /// Deliberately not a bare `.md` — see `GeneratedDocumentCache.fileNameSuffix`.
    static let fileNameSuffix = ".transcript.md"

    private let cache: GeneratedDocumentCache

    var cacheDirectoryURL: URL { cache.cacheDirectoryURL }
    var fileManager: FileManager { cache.fileManager }

    /// Hand-written rather than synthesized: the stored property is now a
    /// `GeneratedDocumentCache`, and a memberwise initialiser over that would
    /// force every call site to construct one.
    init(
        cacheDirectoryURL: URL = GeneratedDocumentCache.supportDirectoryURL(
            named: AgentTranscriptStore.directoryName
        ),
        fileManager: FileManager = .default
    ) {
        cache = GeneratedDocumentCache(
            cacheDirectoryURL: cacheDirectoryURL,
            fileNameSuffix: Self.fileNameSuffix,
            fileManager: fileManager
        )
    }

    // MARK: - Writing

    /// Writes `markdown` to this session's slot, returning the file to open.
    ///
    /// Re-rendering the same session REPLACES the same path rather than
    /// producing a new one — see `GeneratedDocumentCache.write`.
    ///
    /// - Returns: The written file, or `nil` if the cache directory failed
    ///   validation or the write failed. `nil` is the caller's cue to report
    ///   the transcript as unavailable, never to retry somewhere else.
    func write(_ markdown: String, agentKind: AgentKind, sessionID: String) -> URL? {
        cache.write(
            markdown,
            cacheIdentityKey: Self.cacheIdentityKey(agentKind: agentKind, sessionID: sessionID)
        )
    }

    // MARK: - Naming

    func fileURL(agentKind: AgentKind, sessionID: String) -> URL {
        cache.fileURL(
            cacheIdentityKey: Self.cacheIdentityKey(agentKind: agentKind, sessionID: sessionID)
        )
    }

    /// Whether `url` is a slot in this cache — directory membership, not a name
    /// pattern. See `GeneratedDocumentCache.contains`.
    func contains(_ url: URL) -> Bool {
        cache.contains(url)
    }

    func completeWrite(at fileURL: URL) {
        cache.completeWrite(at: fileURL)
    }

    static func cacheFileName(agentKind: AgentKind, sessionID: String) -> String {
        "\(stableHash(cacheIdentityKey(agentKind: agentKind, sessionID: sessionID)))\(fileNameSuffix)"
    }

    /// Length-prefixed, so the boundary between fields cannot be shifted.
    static func cacheIdentityKey(agentKind: AgentKind, sessionID: String) -> String {
        GeneratedDocumentCache.cacheIdentityKey(
            domain: "agent-transcript",
            fields: [agentKind.rawValue, sessionID]
        )
    }

    static func stableHash(_ value: String) -> String {
        GeneratedDocumentCache.stableHash(value)
    }

    // MARK: - Pruning

    func schedulePruneUnreferenced(keeping referencedFileURLs: Set<URL>) {
        cache.schedulePruneUnreferenced(keeping: referencedFileURLs)
    }

    func pruneUnreferencedImmediately(keeping referencedFileURLs: Set<URL>) {
        cache.pruneUnreferencedImmediately(keeping: referencedFileURLs)
    }
}
