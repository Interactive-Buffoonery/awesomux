import AwesoMuxConfig
import CryptoKit
import Foundation

/// The owner-only write/prune mechanics shared by every cache of Markdown
/// awesoMux renders for a document pane to open.
///
/// **Retention.** A generated document is treated as a *restored document*, not
/// as a transient scratch file: it lives exactly as long as a live or
/// recently-closed document tab references it. A write remains protected until
/// its caller finishes the tab-open reaction, plus the first prune that safely
/// crosses that boundary; later fresh prunes can delete it once its last
/// reference goes away. Scheduled prunes capture the authored set and a
/// generation, so a stale keep-set cannot delete a write that landed after it
/// was captured. Once a later prune has crossed that boundary, the authored
/// record is retired and ordinary live/recently-closed references become
/// authoritative again.
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
    /// A scheduled prune captures its references and authored generation before
    /// running later. A render landing between capture and deletion is protected
    /// by its newer generation; a write whose tab-open reaction is unfinished is
    /// protected by a pending lease. Completed entries retire once a later prune
    /// has crossed their generation, keeping this registry bounded.
    /// `RemoteMarkdownSnapshotFetcher` solves the same race with a per-directory
    /// task tail because its writes are eight-second SSH round trips that must
    /// not block their caller; a generated-document write is a local write of a
    /// couple of MiB at most, from a user-initiated command.
    ///
    /// **One global lock and one global authored registry, across every cache
    /// directory — deliberately, not pending.** An earlier note here said to
    /// key both by directory once a second cache existed. A second cache now
    /// does exist (branch changes beside agent transcripts) and the shared
    /// pair is still correct, for two independent reasons. The authored registry
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

    private struct AuthoredPathState {
        /// The newest prune already scheduled when this write landed.
        var createdAfterPruneID: Int
        /// Cleared only after the caller has either opened the tab or abandoned
        /// the reaction. Pending writes are never candidates for retirement.
        var isPending: Bool
    }

    /// Same-process write leases, keyed by standardized absolute path.
    // `nonisolated(unsafe)` promise: accessed only under `cacheLock`.
    nonisolated(unsafe) private static var authoredPaths: [String: AuthoredPathState] = [:]
    nonisolated(unsafe) private static var nextPruneID = 0

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
            Self.authoredPaths[fileURL.standardizedFileURL.path] = AuthoredPathState(
                createdAfterPruneID: Self.nextPruneID,
                isPending: true
            )
            return fileURL
        }
    }

    /// Releases the write lease after the caller has completed its main-actor
    /// tab reaction. The next generation-crossing prune may retire the registry
    /// entry; a live or recently-closed tab still keeps the file itself.
    func completeWrite(at fileURL: URL) {
        let path = fileURL.standardizedFileURL.path
        Self.cacheLock.withLock {
            guard var state = Self.authoredPaths[path] else { return }
            state.isPending = false
            Self.authoredPaths[path] = state
        }
    }

    // MARK: - Naming

    func fileURL(cacheIdentityKey: String) -> URL {
        cacheDirectoryURL.appending(path: cacheFileName(cacheIdentityKey: cacheIdentityKey))
    }

    /// Returns a completed shared slot after another invocation won its write.
    /// The cache lock makes the losing claim observe the winner after its atomic
    /// write, never halfway through it.
    func existingFileURL(cacheIdentityKey: String) -> URL? {
        let candidate = fileURL(cacheIdentityKey: cacheIdentityKey)
        return Self.cacheLock.withLock {
            guard
                fileManager.validatedOwnerOnlyDirectory(
                    at: cacheDirectoryURL,
                    createIfMissing: false
                ) != nil,
                let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey]),
                values.isRegularFile == true
            else { return nil }
            return candidate
        }
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
    /// references the caller could not know about at scheduling are protected
    /// by the captured authored generation and pending-write leases.
    func schedulePruneUnreferenced(keeping referencedFileURLs: Set<URL>) {
        let cache = self
        let scheduled = scheduledPrune()
        Task.detached(priority: .utility) {
            cache.pruneUnreferenced(
                keeping: referencedFileURLs,
                scheduledID: scheduled.id,
                protecting: scheduled.authoredPaths
            )
        }
    }

    func pruneUnreferencedImmediately(keeping referencedFileURLs: Set<URL>) {
        let scheduled = scheduledPrune()
        pruneUnreferenced(
            keeping: referencedFileURLs,
            scheduledID: scheduled.id,
            protecting: scheduled.authoredPaths
        )
    }

    private func scheduledPrune() -> (id: Int, authoredPaths: Set<String>) {
        Self.cacheLock.withLock {
            Self.nextPruneID += 1
            let paths = Set(Self.authoredPaths.keys.filter(belongsToThisCache))
            return (Self.nextPruneID, paths)
        }
    }

    private func pruneUnreferenced(
        keeping referencedFileURLs: Set<URL>,
        scheduledID: Int,
        protecting authoredAtScheduling: Set<String>
    ) {
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
            referencedPaths.formUnion(authoredAtScheduling)
            // A write after this prune was scheduled was absent from both the
            // captured authored set and the caller's earlier keep-set. Pending
            // writes need the same protection even when they predate the prune:
            // their tab-open reaction has not reached SessionStore yet.
            referencedPaths.formUnion(
                Self.authoredPaths.compactMap { path, state in
                    guard belongsToThisCache(path),
                        state.isPending || state.createdAfterPruneID >= scheduledID
                    else { return nil }
                    return path
                }
            )
            for entry in entries where !referencedPaths.contains(entry.standardizedFileURL.path) {
                // Only the regular files a cache writes are ours to delete.
                guard
                    ((try? entry.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile)
                        == true
                else { continue }
                try? fileManager.removeItem(at: entry)
            }

            // Once a completed write has survived a prune scheduled strictly
            // after it landed, future prunes can trust their fresh store-derived
            // keep-set. Pending and post-schedule writes remain leased.
            Self.authoredPaths = Self.authoredPaths.filter { path, state in
                !belongsToThisCache(path)
                    || state.isPending
                    || state.createdAfterPruneID >= scheduledID
            }
        }
    }

    private func belongsToThisCache(_ path: String) -> Bool {
        URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL.path
            == cacheDirectoryURL.standardizedFileURL.path
    }
}
