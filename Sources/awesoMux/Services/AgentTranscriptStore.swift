import AwesoMuxBridgeProtocol
import AwesoMuxCore
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
    /// - Parameter skippingUnchanged: Return the existing path without writing
    ///   when the slot is already a `0o600` file whose contents hash to this
    ///   render's digest. A live-refreshing session re-renders on every
    ///   filesystem event, and most of those events change nothing this
    ///   document shows; rewriting anyway costs an atomic rename, a watcher
    ///   re-arm, a document reload, and a main-actor attributed-string rebuild
    ///   to arrive at the bytes already on screen.
    ///   The check reads the slot back through the same owner-only ingress the
    ///   write uses rather than trusting a record of the last write: a record
    ///   describes what this process *did*, and the question the skip actually
    ///   asks is what is on disk *now*. An external prune between two refreshes
    ///   would otherwise leave the tab pointing at a file the skip declines to
    ///   restore, for the rest of the session.
    /// - Parameter shouldCommit: Consulted as the first statement of the
    ///   write's critical section by a caller that can have several renders of
    ///   the same session in flight, so no other write can land between the
    ///   answer and the bytes. Answering `false` leaves the slot as it stands
    ///   and reports it unchanged — the render that superseded this one owns
    ///   its contents. `NSLock` is not reentrant, so this check can move into
    ///   the lock but the lock can never move out to the caller.
    /// - Returns: The written file, or `nil` if the cache directory failed
    ///   validation or the write failed. `nil` is the caller's cue to report
    ///   the transcript as unavailable, never to retry somewhere else.
    func write(
        _ markdown: String,
        agentKind: AgentKind,
        sessionID: String,
        skippingUnchanged: Bool = false,
        shouldCommit: () -> Bool = { true }
    ) -> URL? {
        let key = Self.cacheIdentityKey(agentKind: agentKind, sessionID: sessionID)
        var commitWasRefused = false
        let written = cache.write(
            markdown,
            cacheIdentityKey: key,
            skippingUnchanged: skippingUnchanged,
            maximumExistingBytes: AgentTranscriptRenderer.budgetBytes,
            ifStillCurrent: {
                let accepted = shouldCommit()
                commitWasRefused = !accepted
                return accepted
            }
        )
        return commitWasRefused ? cache.fileURL(cacheIdentityKey: key) : written
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

    static func stableHash(_ data: Data) -> String {
        GeneratedDocumentCache.stableHash(data)
    }

    // MARK: - Pruning

    func schedulePruneUnreferenced(keeping referencedFileURLs: Set<URL>) {
        cache.schedulePruneUnreferenced(keeping: referencedFileURLs)
    }

    func pruneUnreferencedImmediately(keeping referencedFileURLs: Set<URL>) {
        cache.pruneUnreferencedImmediately(keeping: referencedFileURLs)
    }
}
