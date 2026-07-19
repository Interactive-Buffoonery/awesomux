import AwesoMuxConfig
import AwesoMuxCore
import Foundation
import os

@MainActor
enum SessionPersistence {
    nonisolated private static let logger = Logger(
        subsystem: "com.interactivebuffoonery.awesomux",
        category: "SessionPersistence"
    )

    nonisolated private static let maxSnapshotBytes = 4 * 1024 * 1024
    /// Maximum `{`/`[` nesting depth tolerated before a snapshot is treated as
    /// pathological and quarantined WITHOUT being decoded. `TerminalPaneLayout`
    /// is an `indirect enum` whose `Codable` decode recurses per nested `split`;
    /// a deeply nested chain (well under `maxSnapshotBytes`) overflows the stack
    /// DURING decode — a SIGSEGV below `load()`'s `do/catch` that bypasses
    /// quarantine and crash-loops on every launch (M6). Set far above any legit
    /// snapshot — the restore reducer already collapses layouts past depth 64,
    /// and each split level is ~3 braces in the encoded format — yet far below
    /// the recursion depth that overflows the stack, so we reject before decode
    /// is ever attempted.
    // Kept below `TerminalSplit.maxDecodedSplitDepth` (in brace terms) so any
    // snapshot that survives this pre-scan decodes fully and reaches the
    // per-session use-time collapse, rather than tripping the model's decode
    // guard and quarantining the whole snapshot — preserve that ordering.
    nonisolated static let maxSnapshotNestingDepth = 256
    nonisolated private static let debounceInterval: Duration = .milliseconds(500)
    nonisolated private static let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        // Sorted keys keep the digest stable if any Dictionary ever enters
        // the persisted graph — Swift's default JSONEncoder emits dictionary
        // keys in unspecified order, which would silently defeat the
        // digest-based write-skip without any visible failure.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
    nonisolated private static let jsonEncoderLock = NSLock()
    nonisolated private static let lastWrittenDigestLock = NSLock()
    // Guards `environment`: the `supportDirectoryURL` getter is `nonisolated`
    // and read from the detached write Task, while `withTemporarySupportDirectory`
    // mutates it from the MainActor. Without this lock the `nonisolated(unsafe)`
    // annotation would be promising a synchronization the code doesn't provide.
    nonisolated private static let environmentLock = NSLock()
    nonisolated private static let archiveDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ssZ"
        return formatter
    }()
    struct Environment: Sendable {
        var supportDirectoryURL: URL
    }

    nonisolated(unsafe) private static var environment = Environment(
        supportDirectoryURL: AppRuntimeProfile.current.supportDirectoryURL
    )
    private static var pendingWrite: Task<Void, Never>?
    nonisolated(unsafe) private static var digestWriteGate = StableDataDigestWriteGate()

    struct LoadResult {
        var store: SessionStore
        var recoveryWarning: SessionRecoveryWarning?
    }

    struct SessionRecoveryWarning: Identifiable {
        enum Kind {
            case archivedSnapshot(archivedSnapshotURL: URL?, archiveError: String?)
            case sanitizedRestore(
                summary: SessionRestoreSanitizationSummary,
                archivedSnapshotURL: URL?,
                archiveError: String?
            )
        }

        let id = UUID()
        let kind: Kind

        var archivedSnapshotURL: URL? {
            switch kind {
            case let .archivedSnapshot(url, _),
                let .sanitizedRestore(_, url, _):
                return url
            }
        }

        var archiveError: String? {
            switch kind {
            case let .archivedSnapshot(_, error),
                let .sanitizedRestore(_, _, error):
                return error
            }
        }

        var sanitizationSummary: SessionRestoreSanitizationSummary? {
            guard case let .sanitizedRestore(summary, _, _) = kind else {
                return nil
            }
            return summary
        }

        var preventsInitialSave: Bool {
            switch kind {
            case .archivedSnapshot:
                true
            case let .sanitizedRestore(_, archivedSnapshotURL, _):
                // Only let the cleaned state overwrite the live snapshot once
                // the dirty original is safely archived. If archiving failed,
                // the on-disk file is the only remaining copy of the user's
                // data — don't clobber it.
                archivedSnapshotURL == nil
            }
        }
    }

    static func load() -> LoadResult {
        guard FileManager.default.fileExists(atPath: snapshotURL.path) else {
            let store = SessionStore()
            scheduleRemoteMarkdownSnapshotPrune(keeping: store)
            return LoadResult(store: store)
        }

        let data: Data
        do {
            data = try Data(contentsOf: snapshotURL)
        } catch {
            logger.error("failed to read session snapshot: \(error.localizedDescription, privacy: .public)")
            let archiveResult = archiveCorruptedSnapshot()
            return LoadResult(
                store: SessionStore(),
                recoveryWarning: SessionRecoveryWarning(
                    kind: .archivedSnapshot(
                        archivedSnapshotURL: archiveResult.url,
                        archiveError: archiveResult.error
                    )
                )
            )
        }

        guard data.count <= maxSnapshotBytes else {
            logger.error("session snapshot exceeds maximum supported size: \(data.count, privacy: .public) bytes")
            let archiveResult = archiveCorruptedSnapshot()
            return LoadResult(
                store: SessionStore(),
                recoveryWarning: SessionRecoveryWarning(
                    kind: .archivedSnapshot(
                        archivedSnapshotURL: archiveResult.url,
                        archiveError: archiveResult.error
                    )
                )
            )
        }

        guard !data.isEmpty else {
            logger.error("session snapshot is empty")
            let archiveResult = archiveCorruptedSnapshot()
            return LoadResult(
                store: SessionStore(),
                recoveryWarning: SessionRecoveryWarning(
                    kind: .archivedSnapshot(
                        archivedSnapshotURL: archiveResult.url,
                        archiveError: archiveResult.error
                    )
                )
            )
        }

        // Reject pathologically nested JSON BEFORE decoding it. The recursive
        // `TerminalPaneLayout` decode would otherwise overflow the stack on a
        // deeply nested `split` chain — a SIGSEGV that bypasses the do/catch
        // below and crash-loops every launch (M6). This linear byte scan is the
        // only check that can run safely ahead of the recursion.
        guard maxJSONNestingDepth(in: data) <= maxSnapshotNestingDepth else {
            logger.error("session snapshot nesting depth exceeds safe limit")
            let archiveResult = archiveCorruptedSnapshot()
            return LoadResult(
                store: SessionStore(),
                recoveryWarning: SessionRecoveryWarning(
                    kind: .archivedSnapshot(
                        archivedSnapshotURL: archiveResult.url,
                        archiveError: archiveResult.error
                    )
                )
            )
        }

        do {
            let snapshot = try SessionSnapshot.decode(from: data)
            let restored = SessionStore.restore(from: snapshot)
            scheduleRemoteMarkdownSnapshotPrune(keeping: restored.store)
            guard !restored.sanitizationSummary.isEmpty else {
                updateLastWrittenDigest(StableDataDigest(data: data))
                return LoadResult(store: restored.store, recoveryWarning: nil)
            }

            // Something was adjusted (possibly only structural IDs) → preserve
            // the exact bytes we decoded before the cleaned state is allowed to
            // overwrite the live file.
            let archiveResult = archiveSanitizedOriginalSnapshot(data)
            updateLastWrittenDigest(StableDataDigest(data: data))

            // Structural-only adjustments (e.g. rewritten duplicate IDs) aren't
            // meaningful to explain, so archive silently — UNLESS archiving
            // failed, in which case we must surface the warning so its
            // `preventsInitialSave` guard stops the cleaned state from
            // overwriting the un-archived original.
            guard
                restored.sanitizationSummary.hasUserVisibleAdjustments
                    || archiveResult.url == nil
            else {
                return LoadResult(store: restored.store, recoveryWarning: nil)
            }

            return LoadResult(
                store: restored.store,
                recoveryWarning: SessionRecoveryWarning(
                    kind: .sanitizedRestore(
                        summary: restored.sanitizationSummary,
                        archivedSnapshotURL: archiveResult.url,
                        archiveError: archiveResult.error
                    )
                )
            )
        } catch {
            logger.error("failed to decode session snapshot: \(error.localizedDescription, privacy: .public)")
            let archiveResult = archiveCorruptedSnapshot()
            return LoadResult(
                store: SessionStore(),
                recoveryWarning: SessionRecoveryWarning(
                    kind: .archivedSnapshot(
                        archivedSnapshotURL: archiveResult.url,
                        archiveError: archiveResult.error
                    )
                )
            )
        }
    }

    static func scheduleRemoteMarkdownSnapshotPrune(keeping store: SessionStore) {
        let urls = remoteMarkdownSnapshotURLs(keeping: store)
        let cacheDirectoryURL =
            supportDirectoryURL
            .appending(path: "remote-markdown", directoryHint: .isDirectory)
        Task.detached(priority: .utility) {
            RemoteMarkdownSnapshotFetcher(cacheDirectoryURL: cacheDirectoryURL)
                .pruneUnreferencedSnapshots(keeping: urls)
        }
    }

    static func pruneRemoteMarkdownSnapshotsForTesting(keeping store: SessionStore) {
        RemoteMarkdownSnapshotFetcher()
            .pruneUnreferencedSnapshots(keeping: remoteMarkdownSnapshotURLs(keeping: store))
    }

    private static func remoteMarkdownSnapshotURLs(keeping store: SessionStore) -> Set<URL> {
        let urls = store.groups.reduce(into: Set<URL>()) { urls, group in
            for session in group.sessions {
                collectRemoteMarkdownSnapshotURLs(from: session.layout, into: &urls)
            }
        }
        return store.recentlyClosed.reduce(into: urls) { urls, entry in
            collectRemoteMarkdownSnapshotURLs(from: entry.layout, into: &urls)
        }
    }

    private static func collectRemoteMarkdownSnapshotURLs(
        from layout: TerminalPaneLayout,
        into urls: inout Set<URL>
    ) {
        switch layout {
        case .pane:
            return
        case let .documentGroup(group):
            for tab in group.tabs
            where tab.remoteResourceIdentity?.isSupportedRemoteMarkdownSnapshot == true {
                urls.insert(tab.fileURL)
            }
        case let .split(split):
            collectRemoteMarkdownSnapshotURLs(from: split.first, into: &urls)
            collectRemoteMarkdownSnapshotURLs(from: split.second, into: &urls)
        }
    }

    /// The maximum `{`/`[` nesting depth in `data`. A single allocation-free
    /// byte pass that skips string contents (so braces inside titles or working
    /// directories don't inflate the count) and ignores escaped quotes. Used to
    /// reject pathologically nested snapshots before the recursive decode (M6).
    nonisolated static func maxJSONNestingDepth(in data: Data) -> Int {
        var depth = 0
        var maxDepth = 0
        var inString = false
        var escaped = false
        for byte in data {
            if inString {
                if escaped {
                    escaped = false
                } else if byte == 0x5C {  // backslash
                    escaped = true
                } else if byte == 0x22 {  // closing quote
                    inString = false
                }
                continue
            }
            switch byte {
            case 0x22:  // opening quote
                inString = true
            case 0x7B, 0x5B:  // { or [
                depth += 1
                if depth > maxDepth {
                    maxDepth = depth
                }
            case 0x7D, 0x5D:  // } or ]
                // Clamp at 0: a malformed file with leading unbalanced closers
                // must not drive `depth` negative and undercount a later genuine
                // nesting run (review finding). Valid JSON is balanced, so this is a no-op
                // for it; malformed JSON fails the decode below regardless.
                if depth > 0 {
                    depth -= 1
                }
            default:
                break
            }
        }
        return maxDepth
    }

    /// Coalesces high-frequency mutations (title/cwd updates that fire on every
    /// shell prompt) into a single atomic write. `snapshot()` is O(1) on the
    /// MainActor side because `[SessionGroup]` is COW, so eager capture is
    /// cheap and lets the detached Task stay isolation-free.
    static func save(_ store: SessionStore) {
        let snapshot = store.snapshot()
        pendingWrite?.cancel()
        pendingWrite = Task.detached(priority: .utility) {
            try? await Task.sleep(for: debounceInterval)
            guard !Task.isCancelled else { return }
            writeSnapshot(snapshot, isCancelled: { Task.isCancelled })
        }
    }

    /// Cancels any pending debounced write before doing a synchronous final
    /// write. Call from `applicationWillTerminate`.
    static func flush(_ store: SessionStore) {
        if let task = pendingWrite {
            pendingWrite = nil
            task.cancel()
        }
        writeSnapshot(store.snapshot())
    }

    nonisolated private static func writeSnapshot(
        _ snapshot: SessionSnapshot,
        isCancelled: () -> Bool = { false }
    ) {
        do {
            try FileManager.default.createOwnerOnlyDirectory(at: supportDirectoryURL)
            try FileManager.default.setOwnerOnlyPermissions(onDirectoryAt: supportDirectoryURL)

            let data = try encodeSnapshot(snapshot)
            let digest = StableDataDigest(data: data)

            // Single critical section across check → write → record so two
            // concurrent saves of the same payload can't both pass the gate
            // and double-write. The fileExists check is what fixes the
            // silent durability bug: if `session-state.json` was externally
            // deleted while the app was running, the in-memory digest would
            // otherwise still match and the terminate-time flush would
            // leave no restore file at all.
            lastWrittenDigestLock.lock()
            defer { lastWrittenDigestLock.unlock() }
            // Re-check cancellation inside the lock, not just before the sleep:
            // `flush()`'s `task.cancel()` happens-before its own synchronous
            // `writeSnapshot`, so whichever holder wins this lock, the debounced
            // task either writes first (then flush overwrites) or sees cancelled
            // and skips — it can never clobber flush's newer snapshot with stale
            // bytes. `flush()` passes the default `{ false }`, so its write is
            // never suppressed by ambient cancellation of the terminate context.
            guard !isCancelled() else { return }
            let snapshotPath = snapshotURL.path
            let snapshotIsUsable =
                FileManager.default.fileExists(atPath: snapshotPath)
                && FileManager.default.isReadableFile(atPath: snapshotPath)
            guard digestWriteGate.shouldWrite(digest, snapshotFileExists: snapshotIsUsable) else {
                return
            }

            try data.write(to: snapshotURL, options: [.atomic])
            // Only record the digest once the file is secured. A swallowed chmod
            // failure would leave the snapshot world-readable AND gate every
            // future unchanged save behind the digest, so the bad permissions
            // would persist until content changes. Skipping recordWritten lets
            // the next save (or terminate-time flush) retry the write + chmod.
            try FileManager.default.setOwnerOnlyPermissions(onFileAt: snapshotURL)
            digestWriteGate.recordWritten(digest)
        } catch {
            logger.error("failed to save session snapshot: \(error.localizedDescription, privacy: .public)")
        }
    }

    nonisolated private static func archiveCorruptedSnapshot() -> (url: URL?, error: String?) {
        if isSnapshotSymlink {
            let message = "refusing to archive symbolic-link session snapshot"
            logger.error("\(message, privacy: .public)")
            try? FileManager.default.removeItem(at: snapshotURL)
            return (nil, message)
        }

        let archiveURL = supportDirectoryURL.appending(
            path: "session-state.corrupted-\(archiveTimestamp())-\(UUID().uuidString.prefix(8)).json"
        )

        guard !FileManager.default.fileExists(atPath: archiveURL.path) else {
            let message = "refusing to archive session snapshot because destination exists"
            logger.error("\(message, privacy: .public)")
            return (nil, message)
        }

        do {
            try FileManager.default.moveItem(at: snapshotURL, to: archiveURL)
            setPrivatePermissions(on: archiveURL)
            logger.error("archived unreadable session snapshot to \(archiveURL.path, privacy: .public)")
            pruneQuarantineArchives(prefix: "session-state.corrupted-")
            return (archiveURL, nil)
        } catch {
            let message = error.localizedDescription
            logger.error("failed to archive unreadable session snapshot: \(message, privacy: .public)")
            return (nil, message)
        }
    }

    nonisolated private static func archiveSanitizedOriginalSnapshot(
        _ originalData: Data
    ) -> (url: URL?, error: String?) {
        if isSnapshotSymlink {
            let message = "refusing to archive symbolic-link session snapshot"
            logger.error("\(message, privacy: .public)")
            return (nil, message)
        }

        let archiveURL = supportDirectoryURL.appending(
            path: "session-state.sanitized-\(archiveTimestamp())-\(UUID().uuidString.prefix(8)).json"
        )

        guard !FileManager.default.fileExists(atPath: archiveURL.path) else {
            let message = "refusing to archive session snapshot because destination exists"
            logger.error("\(message, privacy: .public)")
            return (nil, message)
        }

        do {
            try FileManager.default.createOwnerOnlyDirectory(at: supportDirectoryURL)
            try FileManager.default.setOwnerOnlyPermissions(onDirectoryAt: supportDirectoryURL)
            // Write the exact bytes we already decoded rather than re-reading
            // the file by path: a path copy can race a concurrent swap (TOCTOU)
            // and preserve the wrong snapshot, and `copyItem` would follow a
            // symlink at the source. Writing `originalData` guarantees the
            // archive matches the snapshot that produced this sanitized restore.
            try originalData.write(to: archiveURL, options: [.atomic])
            setPrivatePermissions(on: archiveURL)
            logger.error("archived sanitized session snapshot to \(archiveURL.path, privacy: .public)")
            pruneQuarantineArchives(prefix: "session-state.sanitized-")
            return (archiveURL, nil)
        } catch {
            let message = error.localizedDescription
            logger.error("failed to archive sanitized session snapshot: \(message, privacy: .public)")
            return (nil, message)
        }
    }

    nonisolated private static var isSnapshotSymlink: Bool {
        ((try? snapshotURL.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink) == true
    }

    nonisolated private static func archiveTimestamp() -> String {
        archiveDateFormatter.string(from: Date())
    }

    /// Keep only the most recent `maxQuarantineArchives` `session-state.<kind>-`
    /// files so repeated truncations (power loss, disk full) can't accumulate
    /// quarantine files indefinitely. Best-effort: sort by creation date and
    /// trash the oldest excess.
    nonisolated static let maxQuarantineArchives = 10

    nonisolated private static func pruneQuarantineArchives(prefix: String) {
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: supportDirectoryURL,
                includingPropertiesForKeys: [.creationDateKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return
        }
        let archives = entries.filter { $0.lastPathComponent.hasPrefix(prefix) }
        guard archives.count > maxQuarantineArchives else { return }
        let byOldestFirst = archives.sorted {
            let lhs = (try? $0.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            let rhs = (try? $1.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            return lhs < rhs
        }
        for stale in byOldestFirst.prefix(archives.count - maxQuarantineArchives) {
            try? FileManager.default.removeItem(at: stale)
        }
    }

    nonisolated private static func encodeSnapshot(_ snapshot: SessionSnapshot) throws -> Data {
        jsonEncoderLock.lock()
        defer { jsonEncoderLock.unlock() }
        return try jsonEncoder.encode(snapshot)
    }

    nonisolated private static func updateLastWrittenDigest(_ digest: StableDataDigest) {
        lastWrittenDigestLock.lock()
        defer { lastWrittenDigestLock.unlock() }
        digestWriteGate.recordWritten(digest)
    }

    static func withTemporarySupportDirectory<T>(
        _ url: URL,
        operation: () throws -> T
    ) rethrows -> T {
        let previousEnvironment = readEnvironment()
        resetWriteState()
        writeEnvironment(Environment(supportDirectoryURL: url))
        defer {
            resetWriteState()
            writeEnvironment(previousEnvironment)
            resetWriteState()
        }
        return try operation()
    }

    nonisolated private static func readEnvironment() -> Environment {
        environmentLock.lock()
        defer { environmentLock.unlock() }
        return environment
    }

    nonisolated private static func writeEnvironment(_ newValue: Environment) {
        environmentLock.lock()
        defer { environmentLock.unlock() }
        environment = newValue
    }

    private static func resetWriteState() {
        if let task = pendingWrite {
            pendingWrite = nil
            task.cancel()
        }
        lastWrittenDigestLock.lock()
        digestWriteGate = StableDataDigestWriteGate()
        lastWrittenDigestLock.unlock()
    }

    nonisolated private static func setPrivatePermissions(on url: URL) {
        do {
            try FileManager.default.setOwnerOnlyPermissions(onFileAt: url)
        } catch {
            logger.error(
                "failed to set private permissions on \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    nonisolated private static var snapshotURL: URL {
        supportDirectoryURL.appending(path: "session-state.json")
    }

    nonisolated static var supportDirectoryURL: URL {
        readEnvironment().supportDirectoryURL
    }
}
