import AwesoMuxBridgeProtocol
import AwesoMuxConfig
import CryptoKit
import Foundation

/// The owner-only cache holding agent transcripts rendered to Markdown, so a
/// document pane has a real `.md` file to open.
///
/// **Retention.** A rendered transcript is treated as a *restored document*,
/// not as a transient scratch file: it lives exactly as long as a live or
/// recently-closed document tab references it, and is deleted by the first
/// prune after that last reference goes away. Those prunes run at launch, at
/// every snapshot load, and after a recovery replacement — the same lifecycle
/// points that already cover remote Markdown snapshots, through the same
/// collector. One bound on "first": a file this process wrote is never pruned
/// by this process (see `authoredPaths`), so a transcript orphaned mid-session
/// waits for the next launch's prune. That over-keeps bounded plaintext (at
/// most a handful of ≤1.5 MiB files) on exactly the failure side the prune
/// exists to take: the converse is deleting the file under a live tab.
///
/// The exposure that buys is deliberate and worth stating plainly: the file is
/// a plaintext copy of whatever passed through the session, which routinely
/// includes pasted credentials, file contents, and command output. It is
/// therefore written `0o600` inside a `0o700` directory, never under
/// `NSTemporaryDirectory()`, and nothing here logs a path — a filename is a
/// hash and a path would name the user's home.
///
/// The alternative shape (purge on tab close and at launch) was rejected
/// because a restored transcript tab is the case the feature most needs to
/// work: after a relaunch the pane reattaches to a still-live agent with blank
/// scrollback (ADR-0011), and a tab pointing at a purged file is exactly the
/// dead end the prune-must-cover-`recentlyClosed` rule exists to prevent.
// FileManager is documented as safe to use from multiple threads but does not
// yet declare Sendable; the remaining stored values are Sendable. Same posture
// as `RemoteMarkdownSnapshotFetcher`.
struct AgentTranscriptStore: @unchecked Sendable {
    static let directoryName = "agent-transcripts"

    /// Deliberately not a bare `.md`. `RemoteMarkdownSnapshotFetcher` states
    /// the invariant this inherits: an app-authored copy is never presented as
    /// the user's own file, so a generated document must not occupy a slot a
    /// user-content reader would hand back as theirs. The extension still ends
    /// in `.md` because `DocumentURLValidator.allowedExtensions` is the gate
    /// that lets the document pane open this at all, and widening it would also
    /// widen link interception, the file browser, and the enumerator.
    static let fileNameSuffix = ".transcript.md"

    /// One lock covering the whole cache directory, held across a write and
    /// across a prune's enumerate-then-delete. Without it, a prune that
    /// enumerated before the new tab reached the store deletes the file a
    /// render just wrote and the document pane opens onto nothing.
    ///
    /// The lock orders the filesystem operations; it cannot refresh a keep-set.
    /// A scheduled prune captures its references at scheduling and runs later,
    /// and recovery replacement schedules such prunes mid-session: a render
    /// landing in between writes a file the captured set has never heard of,
    /// which the prune would then delete from under the freshly opened tab,
    /// whichever side of the write its enumeration lands on. So the prune
    /// unions the keep-set with `authoredPaths` INSIDE the lock — exactly the
    /// files this process put there, consistent with the state being
    /// enumerated by construction.
    /// `RemoteMarkdownSnapshotFetcher` solves the same race with a per-directory
    /// task tail because its writes are eight-second SSH round trips that must
    /// not block their caller; a transcript write is a local write of at most
    /// 1.5 MiB from a user-initiated command.
    ///
    /// Note: one global lock and one global authored set, not one per
    /// directory. Key both by directory path if a second transcript cache
    /// directory ever exists.
    nonisolated private static let cacheLock = NSLock()

    /// Every transcript path this process has written, standardized, guarded
    /// by `cacheLock` and unioned into every prune's keep-set (rationale on
    /// `cacheLock`). Registered only on a successful write, so it can promise
    /// "this process put bytes at this path": entries never name a file that
    /// failed to land. Nothing removes entries mid-session, because nothing in
    /// this process can prove a path's last reference died — the keep-set that
    /// would say so is exactly the stale input being defended against. The
    /// next launch's prune consults a fresh keep-set and collects anything
    /// genuinely orphaned.
    // `nonisolated(unsafe)` promise: accessed only under `cacheLock`.
    nonisolated(unsafe) private static var authoredPaths: Set<String> = []

    var cacheDirectoryURL: URL = SessionPersistence.supportDirectoryURL
        .appending(path: AgentTranscriptStore.directoryName, directoryHint: .isDirectory)
    var fileManager: FileManager = .default

    // MARK: - Writing

    /// Writes `markdown` to this session's slot, returning the file to open.
    ///
    /// Re-rendering the same session REPLACES the same path rather than
    /// producing a new one. That is load-bearing, not an oversight worth
    /// "fixing": `DocumentGroup.tab(forNormalizedURL:)` dedupes tabs by URL and
    /// `DocumentFileWatcher` re-arms across the atomic rename, so a refresh
    /// updates the already-open tab in place. A per-render unique path would
    /// look tidier and would instead leave one orphaned tab and one orphaned
    /// file behind on every refresh.
    ///
    /// - Returns: The written file, or `nil` if the cache directory failed
    ///   validation or the write failed. `nil` is the caller's cue to report
    ///   the transcript as unavailable, never to retry somewhere else.
    func write(_ markdown: String, agentKind: AgentKind, sessionID: String) -> URL? {
        let fileURL = fileURL(agentKind: agentKind, sessionID: sessionID)
        return Self.cacheLock.withLock {
            guard
                fileManager.validatedOwnerOnlyDirectory(
                    at: cacheDirectoryURL,
                    createIfMissing: true
                ) != nil
            else {
                return nil
            }
            do {
                try fileManager.writeOwnerOnlyFile(at: fileURL, contents: Data(markdown.utf8))
            } catch {
                return nil
            }
            // Registration rides the write's critical section, so a prune can
            // never hold a keep-set this write already falsified.
            Self.authoredPaths.insert(fileURL.standardizedFileURL.path)
            return fileURL
        }
    }

    // MARK: - Naming

    func fileURL(agentKind: AgentKind, sessionID: String) -> URL {
        cacheDirectoryURL.appending(
            path: Self.cacheFileName(agentKind: agentKind, sessionID: sessionID)
        )
    }

    /// Whether `url` is a slot in this cache.
    ///
    /// Directory membership rather than a name pattern: it is the pruner's
    /// actual invariant, and it keeps a user's own file that happens to be
    /// named `something.transcript.md` from being counted as app-authored.
    func contains(_ url: URL) -> Bool {
        url.deletingLastPathComponent().standardizedFileURL.path
            == cacheDirectoryURL.standardizedFileURL.path
    }

    static func cacheFileName(agentKind: AgentKind, sessionID: String) -> String {
        "\(stableHash(cacheIdentityKey(agentKind: agentKind, sessionID: sessionID)))\(fileNameSuffix)"
    }

    /// Length-prefixed, so the boundary between fields cannot be shifted: the
    /// pair `("a", "b")` and the pair `("ab", "")` must not hash to the same
    /// slot. Matches `RemoteMarkdownSnapshotFetcher.cacheIdentityKey`.
    static func cacheIdentityKey(agentKind: AgentKind, sessionID: String) -> String {
        ["agent-transcript", agentKind.rawValue, sessionID]
            .map { "\($0.utf8.count):\($0)" }
            .joined(separator: "|")
    }

    /// Hashed rather than named after the session, for two reasons that both
    /// stand on their own. The session id arrives from a same-UID-writable
    /// event file and, on the bridge path, from a remote host, so the slot
    /// function has to be collision-resistant against a chosen input — 128 bits
    /// of SHA-256 is far past birthday reach for a per-user directory, while a
    /// non-cryptographic hash is solvable. And a filename that *was* the
    /// session id would carry it into every log line and crash report that
    /// names the file, against ADR-0015's "filenames only" rule.
    static func stableHash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .prefix(16)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    // MARK: - Pruning

    /// Captures the keep-set now and prunes off the caller's actor.
    ///
    /// The captured set going stale mid-flight is not an escape hatch:
    /// references the caller could not know about at scheduling are files
    /// written after it, and every prune unions in `authoredPaths` inside the
    /// cache lock, so those files are never deleted by their own process.
    func schedulePruneUnreferenced(keeping referencedFileURLs: Set<URL>) {
        let store = self
        Task.detached(priority: .utility) {
            store.pruneUnreferencedImmediately(keeping: referencedFileURLs)
        }
    }

    func pruneUnreferencedImmediately(keeping referencedFileURLs: Set<URL>) {
        Self.cacheLock.withLock {
            // `createIfMissing: false`: a prune must never bring the directory
            // into existence, and a symlinked cache root is refused here too —
            // otherwise prune becomes a delete primitive aimed wherever the
            // link points.
            guard
                let directory = fileManager.validatedOwnerOnlyDirectory(
                    at: cacheDirectoryURL,
                    createIfMissing: false
                ),
                // `.skipsHiddenFiles` also spares `writeOwnerOnlyFile`'s
                // dot-prefixed temp sibling; the lock already covers that, but
                // the two guards are independent and both cheap.
                let entries = try? fileManager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                )
            else {
                return
            }
            var referencedPaths = Set(referencedFileURLs.map(\.standardizedFileURL.path))
            // The keep-set is a capture from whenever the caller computed it —
            // for a scheduled prune, necessarily before the prune ran. Union in
            // the paths this process wrote: those are exactly the references a
            // stale keep-set can miss, and the union is evaluated under the
            // same lock the writes were taken under, so it is precisely as
            // fresh as the directory being enumerated.
            referencedPaths.formUnion(Self.authoredPaths)
            for entry in entries where !referencedPaths.contains(entry.standardizedFileURL.path) {
                // Only the regular files this store writes are ours to delete.
                guard
                    ((try? entry.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile)
                        == true
                else { continue }
                try? fileManager.removeItem(at: entry)
            }
        }
    }
}
