import AwesoMuxConfig
import CryptoKit
import Foundation

/// The owner-only write/prune mechanics shared by every cache of Markdown
/// awesoMux renders for a document pane to open.
///
/// **Retention.** A generated document is treated as a *restored document*, not
/// as a transient scratch file: it lives exactly as long as a live or
/// recently-closed document tab references it, and is deleted by the first
/// prune after that last reference goes away. Those prunes run at launch, at
/// every snapshot load, and after a recovery replacement — the same lifecycle
/// points that already cover remote Markdown snapshots, through the same
/// collector. One bound on "first": a file this process wrote is never pruned
/// by this process (see `authoredPaths`), so a document orphaned mid-session
/// waits for the next launch's prune. That over-keeps bounded plaintext on
/// exactly the failure side the prune exists to take: the converse is deleting
/// the file under a live tab.
///
/// The exposure that buys is deliberate and worth stating plainly: the file is
/// a plaintext copy of whatever the renderer read, which routinely includes
/// pasted credentials, file contents, and command output. It is therefore
/// written `0o600` inside a `0o700` directory, never under
/// `NSTemporaryDirectory()`, and nothing here logs a path — a filename is a
/// hash and a path would name the user's home.
///
/// The alternative shape (purge on tab close and at launch) was rejected
/// because a restored generated tab is the case the feature most needs to
/// work: after a relaunch the pane reattaches to a still-live agent with blank
/// scrollback (ADR-0011), and a tab pointing at a purged file is exactly the
/// dead end the prune-must-cover-`recentlyClosed` rule exists to prevent.
// FileManager is documented as safe to use from multiple threads but does not
// yet declare Sendable; the remaining stored values are Sendable. Same posture
// as `RemoteMarkdownSnapshotFetcher`.
struct GeneratedDocumentCache: @unchecked Sendable {
    /// Deliberately never a bare `.md`. `RemoteMarkdownSnapshotFetcher` states
    /// the invariant every caller inherits: an app-authored copy is never
    /// presented as the user's own file, so a generated document must not
    /// occupy a slot a user-content reader would hand back as theirs. The
    /// suffix still ends in `.md` because `DocumentURLValidator.allowedExtensions`
    /// is the gate that lets the document pane open this at all, and widening
    /// it would also widen link interception, the file browser, and the
    /// enumerator.
    let fileNameSuffix: String
    let cacheDirectoryURL: URL
    let fileManager: FileManager

    init(cacheDirectoryURL: URL, fileNameSuffix: String, fileManager: FileManager = .default) {
        self.cacheDirectoryURL = cacheDirectoryURL
        self.fileNameSuffix = fileNameSuffix
        self.fileManager = fileManager
    }

    /// The support-directory location for a cache named `directoryName`.
    static func supportDirectoryURL(named directoryName: String) -> URL {
        SessionPersistence.supportDirectoryURL
            .appending(path: directoryName, directoryHint: .isDirectory)
    }

    /// One lock covering every generated-document cache directory, held across
    /// a write and across a prune's enumerate-then-delete. Without it, a prune
    /// that enumerated before the new tab reached the store deletes the file a
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
    /// not block their caller; a generated-document write is a local write of a
    /// couple of MiB at most, from a user-initiated command.
    ///
    /// **One global lock and one global authored set, across every cache
    /// directory — deliberately, not pending.** An earlier note here said to
    /// key both by directory once a second cache existed. A second cache now
    /// does exist (branch changes beside agent transcripts) and the shared
    /// pair is still correct, for two independent reasons. The authored set
    /// holds absolute standardized paths, and a prune deletes only entries it
    /// enumerated inside its own validated directory, so a path authored into
    /// one cache can never match anything another cache's prune is looking at
    /// — the sets are disjoint by construction, and unioning them costs a
    /// membership test against a handful of strings. And the lock's only job is
    /// to order filesystem operations against each other; splitting it would
    /// buy concurrency between two caches that are each written at most once
    /// per user-initiated command. `ponytail: one lock for both caches; key it
    /// by directory if a cache ever appears whose writes are long enough to
    /// make the other cache wait on them.`
    nonisolated private static let cacheLock = NSLock()

    /// Every generated-document path this process has written, standardized,
    /// guarded by `cacheLock` and unioned into every prune's keep-set
    /// (rationale on `cacheLock`). Registered only on a successful write, so it
    /// can promise "this process put bytes at this path": entries never name a
    /// file that failed to land. Nothing removes entries mid-session, because
    /// nothing in this process can prove a path's last reference died — the
    /// keep-set that would say so is exactly the stale input being defended
    /// against. The next launch's prune consults a fresh keep-set and collects
    /// anything genuinely orphaned.
    // `nonisolated(unsafe)` promise: accessed only under `cacheLock`.
    nonisolated(unsafe) private static var authoredPaths: Set<String> = []

    // MARK: - Writing

    /// Writes `markdown` to the slot for `cacheIdentityKey`, returning the file
    /// to open.
    ///
    /// Re-rendering the same identity REPLACES the same path rather than
    /// producing a new one. That is load-bearing, not an oversight worth
    /// "fixing": `DocumentGroup.tab(forNormalizedURL:)` dedupes tabs by URL and
    /// `DocumentFileWatcher` re-arms across the atomic rename, so a refresh
    /// updates the already-open tab in place. A per-render unique path would
    /// look tidier and would instead leave one orphaned tab and one orphaned
    /// file behind on every refresh.
    ///
    /// - Parameter ifStillCurrent: Evaluated inside the cache lock, immediately
    ///   before the bytes go down, and skipping the write when it answers
    ///   `false`. It is a parameter rather than a check the caller makes first
    ///   because a slot is shared: two renders of the same identity race for one
    ///   path, and a caller that asked "am I still the newest?" and *then* wrote
    ///   would leave the window where the older render answers yes, the newer
    ///   one writes, and the older one overwrites it. Checking under the lock
    ///   that already serializes the writes closes it.
    /// - Returns: The written file, or `nil` if the cache directory failed
    ///   validation, the write failed, or `ifStillCurrent` refused. `nil` is the
    ///   caller's cue to report the document as unavailable, never to retry
    ///   somewhere else.
    func write(
        _ markdown: String,
        cacheIdentityKey: String,
        ifStillCurrent: () -> Bool = { true }
    ) -> URL? {
        let fileURL = fileURL(cacheIdentityKey: cacheIdentityKey)
        return Self.cacheLock.withLock {
            guard ifStillCurrent() else { return nil }
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

    func fileURL(cacheIdentityKey: String) -> URL {
        cacheDirectoryURL.appending(path: cacheFileName(cacheIdentityKey: cacheIdentityKey))
    }

    /// Whether `url` is a slot in this cache.
    ///
    /// Directory membership rather than a name pattern: it is the pruner's
    /// actual invariant, and it keeps a user's own file that happens to carry
    /// the suffix from being counted as app-authored.
    func contains(_ url: URL) -> Bool {
        url.deletingLastPathComponent().standardizedFileURL.path
            == cacheDirectoryURL.standardizedFileURL.path
    }

    func cacheFileName(cacheIdentityKey: String) -> String {
        "\(Self.stableHash(cacheIdentityKey))\(fileNameSuffix)"
    }

    /// Length-prefixed, so the boundary between fields cannot be shifted: the
    /// pair `("a", "b")` and the pair `("ab", "")` must not hash to the same
    /// slot. Matches `RemoteMarkdownSnapshotFetcher.cacheIdentityKey`.
    ///
    /// `domain` is the first field rather than a separate namespace, so two
    /// caches that happen to agree on every remaining field still land on
    /// different slots.
    static func cacheIdentityKey(domain: String, fields: [String]) -> String {
        ([domain] + fields)
            .map { "\($0.utf8.count):\($0)" }
            .joined(separator: "|")
    }

    /// Hashed rather than named after the identity, for two reasons that both
    /// stand on their own. The fields arrive from same-UID-writable event
    /// files, remote hosts, and repository metadata, so the slot function has
    /// to be collision-resistant against a chosen input — 128 bits of SHA-256
    /// is far past birthday reach for a per-user directory, while a
    /// non-cryptographic hash is solvable. And a filename that *was* the
    /// identity would carry it into every log line and crash report that names
    /// the file, against ADR-0015's "filenames only" rule.
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
        let cache = self
        Task.detached(priority: .utility) {
            cache.pruneUnreferencedImmediately(keeping: referencedFileURLs)
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
            // fresh as the directory being enumerated. Paths authored into a
            // sibling cache are absolute and therefore cannot match anything
            // this enumeration returned.
            referencedPaths.formUnion(Self.authoredPaths)
            for entry in entries where !referencedPaths.contains(entry.standardizedFileURL.path) {
                // Only the regular files a cache writes are ours to delete.
                guard
                    ((try? entry.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile)
                        == true
                else { continue }
                try? fileManager.removeItem(at: entry)
            }
        }
    }
}
