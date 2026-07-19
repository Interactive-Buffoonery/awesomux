import AwesoMuxConfig
import AwesoMuxCore
import Darwin
import Foundation
import SecureFileIO
import os

private enum RecoverySnapshotWriteOutcome: Sendable {
    case success
    case snapshotTooLarge
    case writeFailed
}

private final class RecoverySnapshotWriteCoordinator: @unchecked Sendable {
    private let condition = NSCondition()
    private var warningID: UUID?
    private var writeIsActive = false
    private var outcome: RecoverySnapshotWriteOutcome?
    private var gateTransferOutcome: RecoverySnapshotWriteOutcome?

    func beginWrite(for warningID: UUID) {
        condition.lock()
        self.warningID = warningID
        writeIsActive = true
        outcome = nil
        gateTransferOutcome = nil
        condition.unlock()
    }

    func finishWrite(with outcome: RecoverySnapshotWriteOutcome) {
        condition.lock()
        self.outcome = outcome
        writeIsActive = false
        condition.broadcast()
        condition.unlock()
    }

    var hasActiveWrite: Bool {
        condition.lock()
        defer { condition.unlock() }
        return writeIsActive
    }

    func waitForCompletion() -> (warningID: UUID, outcome: RecoverySnapshotWriteOutcome)? {
        condition.lock()
        defer { condition.unlock() }
        while writeIsActive {
            condition.wait()
        }
        guard let warningID, let outcome else { return nil }
        return (warningID, outcome)
    }

    func transferGate(
        for warningID: UUID,
        latestWriteOutcome: RecoverySnapshotWriteOutcome
    ) {
        condition.lock()
        if self.warningID == warningID {
            gateTransferOutcome = latestWriteOutcome
        }
        condition.unlock()
    }

    func transferredGateOutcome(for warningID: UUID) -> RecoverySnapshotWriteOutcome? {
        condition.lock()
        defer { condition.unlock() }
        guard self.warningID == warningID else { return nil }
        return gateTransferOutcome
    }

    func endTransaction(for warningID: UUID) {
        condition.lock()
        if self.warningID == warningID {
            self.warningID = nil
            writeIsActive = false
            outcome = nil
            gateTransferOutcome = nil
        }
        condition.unlock()
    }
}

@MainActor
enum SessionPersistence {
    nonisolated private static let logger = Logger(
        subsystem: "com.interactivebuffoonery.awesomux",
        category: "SessionPersistence"
    )

    nonisolated static let maxSnapshotBytes = 4 * 1024 * 1024
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
    private static var blockedRecoveryWarningID: UUID?
    private static var activeRecoveryReplacementWarningID: UUID?
    nonisolated private static let recoveryWriteCoordinator = RecoverySnapshotWriteCoordinator()
    nonisolated(unsafe) private static var digestWriteGate = StableDataDigestWriteGate()

    struct LoadResult {
        var store: SessionStore
        var recoveryWarning: SessionRecoveryWarning?
    }

    enum RecoverySnapshotReplacementError: Error, Equatable {
        case warningNotActive
        case snapshotTooLarge
        case writeFailed
    }

    struct SessionRecoveryWarning: Identifiable {
        enum Kind {
            case archivedSnapshot(archivedSnapshotURL: URL?, archiveError: String?)
            case snapshotConflict(archivedSnapshotURL: URL?, archiveError: String?)
            case sanitizedRestore(
                summary: SessionRestoreSanitizationSummary,
                archivedSnapshotURL: URL?,
                archiveError: String?
            )
        }

        let id = UUID()
        let kind: Kind
        let protectedSnapshotIdentity: SecureFileIdentity?

        init(
            kind: Kind,
            protectedSnapshotIdentity: SecureFileIdentity? = nil
        ) {
            self.kind = kind
            self.protectedSnapshotIdentity = protectedSnapshotIdentity
        }

        var archivedSnapshotURL: URL? {
            switch kind {
            case let .archivedSnapshot(url, _),
                let .snapshotConflict(url, _),
                let .sanitizedRestore(_, url, _):
                return url
            }
        }

        var archiveError: String? {
            switch kind {
            case let .archivedSnapshot(_, error),
                let .snapshotConflict(_, error),
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
            case .archivedSnapshot, .snapshotConflict:
                true
            case let .sanitizedRestore(_, archivedSnapshotURL, archiveError):
                // Only let the cleaned state overwrite the live snapshot once
                // the dirty original is safely archived and the live path still
                // names the file that was opened. Otherwise a replacement may
                // be the only remaining copy of the user's data.
                archivedSnapshotURL == nil || archiveError != nil
            }
        }

        var allowsAutomaticWritesAfterAcknowledgement: Bool {
            guard case let .archivedSnapshot(archivedSnapshotURL, archiveError) = kind else {
                return false
            }
            return archivedSnapshotURL != nil
                && archiveError == nil
                && protectedSnapshotIdentity != nil
        }
    }

    static func load(
        afterSnapshotOpen: () throws -> Void = {},
        afterCorruptedSnapshotValidation: () throws -> Void = {},
        remoteMarkdownPrune: (SessionStore) -> Void = {
            scheduleRemoteMarkdownSnapshotPrune(keeping: $0)
        }
    ) -> LoadResult {
        blockedRecoveryWarningID = nil
        guard snapshotPathExists else {
            let store = SessionStore()
            remoteMarkdownPrune(store)
            return LoadResult(store: store)
        }

        let data: Data
        var openedIdentity: SecureFileIdentity?
        do {
            let handle = try SecureFileReader.open(
                at: snapshotURL,
                symlinkPolicy: .rejectFinalComponent
            )
            openedIdentity = handle.identity
            guard handle.size <= UInt64(maxSnapshotBytes) else {
                throw SecureFileReadError.tooLarge
            }
            try afterSnapshotOpen()
            data = try handle.read(maximumBytes: maxSnapshotBytes)
        } catch SecureFileReadError.tooLarge {
            logger.error("session snapshot exceeds maximum supported size")
            return failedLoad(
                archiveResult: (
                    nil,
                    "oversized session snapshot was left untouched"
                ),
                protectedSnapshotIdentity: openedIdentity
            )
        } catch {
            logger.error("failed to read session snapshot: \(error.localizedDescription, privacy: .public)")
            return failedLoad(
                archiveResult: (
                    nil,
                    "session snapshot could not be read safely and was left untouched"
                ),
                protectedSnapshotIdentity: openedIdentity
            )
        }

        guard data.count <= maxSnapshotBytes else {
            logger.error("session snapshot exceeds maximum supported size: \(data.count, privacy: .public) bytes")
            let archiveResult = archiveCorruptedSnapshot(
                data,
                expectedIdentity: openedIdentity,
                afterValidation: afterCorruptedSnapshotValidation
            )
            return failedLoad(
                archiveResult: archiveResult,
                protectedSnapshotIdentity: openedIdentity
            )
        }

        guard !data.isEmpty else {
            logger.error("session snapshot is empty")
            let archiveResult = archiveCorruptedSnapshot(
                data,
                expectedIdentity: openedIdentity,
                afterValidation: afterCorruptedSnapshotValidation
            )
            return failedLoad(
                archiveResult: archiveResult,
                protectedSnapshotIdentity: openedIdentity
            )
        }

        // Reject pathologically nested JSON BEFORE decoding it. The recursive
        // `TerminalPaneLayout` decode would otherwise overflow the stack on a
        // deeply nested `split` chain — a SIGSEGV that bypasses the do/catch
        // below and crash-loops every launch (M6). This linear byte scan is the
        // only check that can run safely ahead of the recursion.
        guard maxJSONNestingDepth(in: data) <= maxSnapshotNestingDepth else {
            logger.error("session snapshot nesting depth exceeds safe limit")
            let archiveResult = archiveCorruptedSnapshot(
                data,
                expectedIdentity: openedIdentity,
                afterValidation: afterCorruptedSnapshotValidation
            )
            return failedLoad(
                archiveResult: archiveResult,
                protectedSnapshotIdentity: openedIdentity
            )
        }

        do {
            let snapshot = try SessionSnapshot.decode(from: data)
            let restored = SessionStore.restore(from: snapshot)
            guard !restored.sanitizationSummary.isEmpty else {
                guard let openedIdentity, snapshotPathMatches(openedIdentity) else {
                    return conflictedLoad(
                        store: restored.store,
                        openedData: data,
                        protectedSnapshotIdentity: openedIdentity
                    )
                }
                remoteMarkdownPrune(restored.store)
                updateLastWrittenDigest(StableDataDigest(data: data))
                return LoadResult(store: restored.store, recoveryWarning: nil)
            }

            // Something was adjusted (possibly only structural IDs) → preserve
            // the exact bytes we decoded before the cleaned state is allowed to
            // overwrite the live file.
            let archiveResult = archiveSanitizedOriginalSnapshot(
                data,
                expectedIdentity: openedIdentity
            )
            if archiveResult.error == nil,
                let openedIdentity,
                !snapshotPathMatches(openedIdentity)
            {
                return conflictedLoad(
                    store: restored.store,
                    archiveResult: archiveResult,
                    protectedSnapshotIdentity: openedIdentity
                )
            }
            updateLastWrittenDigest(StableDataDigest(data: data))

            // Structural-only adjustments (e.g. rewritten duplicate IDs) aren't
            // meaningful to explain, so archive silently — UNLESS archiving
            // failed, in which case we must surface the warning so its
            // `preventsInitialSave` guard stops the cleaned state from
            // overwriting the un-archived original.
            guard
                restored.sanitizationSummary.hasUserVisibleAdjustments
                    || archiveResult.url == nil
                    || archiveResult.error != nil
            else {
                remoteMarkdownPrune(restored.store)
                return LoadResult(store: restored.store, recoveryWarning: nil)
            }

            let result = LoadResult(
                store: restored.store,
                recoveryWarning: SessionRecoveryWarning(
                    kind: .sanitizedRestore(
                        summary: restored.sanitizationSummary,
                        archivedSnapshotURL: archiveResult.url,
                        archiveError: archiveResult.error
                    ),
                    protectedSnapshotIdentity: openedIdentity
                )
            )
            if result.recoveryWarning?.preventsInitialSave == true {
                blockedRecoveryWarningID = result.recoveryWarning?.id
            } else {
                remoteMarkdownPrune(restored.store)
            }
            return result
        } catch {
            logger.error("failed to decode session snapshot: \(error.localizedDescription, privacy: .public)")
            let archiveResult = archiveCorruptedSnapshot(
                data,
                expectedIdentity: openedIdentity,
                afterValidation: afterCorruptedSnapshotValidation
            )
            return failedLoad(
                archiveResult: archiveResult,
                protectedSnapshotIdentity: openedIdentity
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
    static func save(
        _ store: SessionStore,
        completion: (@MainActor @Sendable (Result<Void, RecoverySnapshotReplacementError>) -> Void)? = nil
    ) {
        guard blockedRecoveryWarningID == nil else {
            pendingWrite?.cancel()
            pendingWrite = nil
            return
        }
        let snapshot = store.snapshot()
        pendingWrite?.cancel()
        pendingWrite = Task.detached(priority: .utility) {
            try? await Task.sleep(for: debounceInterval)
            guard !Task.isCancelled else { return }
            let result = writeSnapshot(snapshot, isCancelled: { Task.isCancelled })
            guard !Task.isCancelled else { return }
            await completion?(result)
        }
    }

    /// Cancels any pending debounced write before doing a synchronous final
    /// write. If an explicit recovery replacement is outstanding, wait for its
    /// captured snapshot, transfer the recovery gate after success, then write
    /// the latest quit-time state. Call from `applicationWillTerminate`.
    @discardableResult
    static func flush(
        _ store: SessionStore,
        whileWaitingForRecoveryWrite: () -> Void = {}
    ) -> Result<Void, RecoverySnapshotReplacementError> {
        if let task = pendingWrite {
            pendingWrite = nil
            task.cancel()
        }
        if recoveryWriteCoordinator.hasActiveWrite {
            whileWaitingForRecoveryWrite()
        }
        if let completion = recoveryWriteCoordinator.waitForCompletion(),
            blockedRecoveryWarningID == completion.warningID
        {
            switch completion.outcome {
            case .success:
                blockedRecoveryWarningID = nil
                let latestResult = writeSnapshot(store.snapshot())
                recoveryWriteCoordinator.transferGate(
                    for: completion.warningID,
                    latestWriteOutcome: writeOutcome(for: latestResult)
                )
                return latestResult
            case .snapshotTooLarge:
                return .failure(.snapshotTooLarge)
            case .writeFailed:
                return .failure(.writeFailed)
            }
        }
        guard blockedRecoveryWarningID == nil else {
            return .failure(.warningNotActive)
        }
        return writeSnapshot(store.snapshot())
    }

    @discardableResult
    static func acknowledgeRecoveryWarning(_ warning: SessionRecoveryWarning) -> Bool {
        guard
            blockedRecoveryWarningID == warning.id,
            warning.allowsAutomaticWritesAfterAcknowledgement,
            let protectedSnapshotIdentity = warning.protectedSnapshotIdentity,
            snapshotPathMatches(protectedSnapshotIdentity)
        else {
            return false
        }
        blockedRecoveryWarningID = nil
        return true
    }

    /// Replaces a protected snapshot after an explicit user choice. Encoding,
    /// hashing, and owner-only atomic I/O run on a utility task. The ordinary
    /// continuation releases the gate and schedules the latest state; a
    /// concurrent termination flush can instead transfer the gate and persist
    /// that latest state synchronously.
    static func replaceSnapshotAfterRecovery(
        with store: SessionStore,
        warning: SessionRecoveryWarning,
        afterSnapshotCapture: () -> Void = {},
        catchUpSaveCompletion: (
            @MainActor @Sendable (
                Result<Void, RecoverySnapshotReplacementError>
            ) -> Void
        )? = nil,
        snapshotWriter:
            @escaping @Sendable (SessionSnapshot) -> Result<
                Void, RecoverySnapshotReplacementError
            > = {
                writeSnapshot($0, forceWrite: true)
            },
        remoteMarkdownPrune: (SessionStore) -> Void = {
            scheduleRemoteMarkdownSnapshotPrune(keeping: $0)
        }
    ) async -> Result<Void, RecoverySnapshotReplacementError> {
        guard
            blockedRecoveryWarningID == warning.id,
            activeRecoveryReplacementWarningID == nil
        else {
            return .failure(.warningNotActive)
        }
        activeRecoveryReplacementWarningID = warning.id
        if let task = pendingWrite {
            pendingWrite = nil
            task.cancel()
        }

        // Capture the store's COW snapshot on MainActor, then keep JSONEncoder,
        // hashing, and filesystem I/O off the UI thread. JSONEncoder exposes no
        // output-budget hook, so the post-encode byte cap bounds persisted data
        // but cannot prevent the encoder's temporary allocation itself.
        let snapshot = store.snapshot()
        afterSnapshotCapture()
        recoveryWriteCoordinator.beginWrite(for: warning.id)
        let result = await Task.detached(priority: .utility) {
            let result = snapshotWriter(snapshot)
            recoveryWriteCoordinator.finishWrite(with: writeOutcome(for: result))
            return result
        }.value
        if let transferredOutcome = recoveryWriteCoordinator.transferredGateOutcome(
            for: warning.id
        ) {
            activeRecoveryReplacementWarningID = nil
            recoveryWriteCoordinator.endTransaction(for: warning.id)
            catchUpSaveCompletion?(writeResult(for: transferredOutcome))
            return .success(())
        }
        guard case .success = result else {
            activeRecoveryReplacementWarningID = nil
            recoveryWriteCoordinator.endTransaction(for: warning.id)
            return result
        }
        guard blockedRecoveryWarningID == warning.id else {
            activeRecoveryReplacementWarningID = nil
            recoveryWriteCoordinator.endTransaction(for: warning.id)
            return .failure(.warningNotActive)
        }
        blockedRecoveryWarningID = nil
        activeRecoveryReplacementWarningID = nil
        recoveryWriteCoordinator.endTransaction(for: warning.id)
        // The store can change while the utility write is in flight. Persist
        // that newer state through the ordinary coalescing path now that the
        // protected baseline has been replaced successfully.
        save(store, completion: catchUpSaveCompletion)
        remoteMarkdownPrune(SessionStore(restoring: snapshot))
        return .success(())
    }

    nonisolated private static func writeOutcome(
        for result: Result<Void, RecoverySnapshotReplacementError>
    ) -> RecoverySnapshotWriteOutcome {
        switch result {
        case .success:
            return .success
        case .failure(.snapshotTooLarge):
            return .snapshotTooLarge
        case .failure(.warningNotActive), .failure(.writeFailed):
            return .writeFailed
        }
    }

    private static func writeResult(
        for outcome: RecoverySnapshotWriteOutcome
    ) -> Result<Void, RecoverySnapshotReplacementError> {
        switch outcome {
        case .success:
            return .success(())
        case .snapshotTooLarge:
            return .failure(.snapshotTooLarge)
        case .writeFailed:
            return .failure(.writeFailed)
        }
    }

    nonisolated private static func writeSnapshot(
        _ snapshot: SessionSnapshot,
        forceWrite: Bool = false,
        isCancelled: () -> Bool = { false }
    ) -> Result<Void, RecoverySnapshotReplacementError> {
        do {
            try FileManager.default.createOwnerOnlyDirectory(at: supportDirectoryURL)
            try FileManager.default.setOwnerOnlyPermissions(onDirectoryAt: supportDirectoryURL)

            let data = try encodeSnapshot(snapshot)
            guard data.count <= maxSnapshotBytes else {
                logger.error(
                    "refusing to save session snapshot because encoded state exceeds maximum supported size: \(data.count, privacy: .public) bytes"
                )
                return .failure(.snapshotTooLarge)
            }
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
            guard !isCancelled() else { return .success(()) }
            let snapshotPath = snapshotURL.path
            let snapshotIsUsable =
                FileManager.default.fileExists(atPath: snapshotPath)
                && FileManager.default.isReadableFile(atPath: snapshotPath)
            if !forceWrite,
                !digestWriteGate.shouldWrite(digest, snapshotFileExists: snapshotIsUsable)
            {
                return .success(())
            }

            try FileManager.default.writeOwnerOnlyFile(
                at: snapshotURL,
                contents: data
            )
            digestWriteGate.recordWritten(digest)
            return .success(())
        } catch {
            logger.error("failed to save session snapshot: \(error.localizedDescription, privacy: .public)")
            return .failure(.writeFailed)
        }
    }

    private static func failedLoad(
        archiveResult: (url: URL?, error: String?),
        protectedSnapshotIdentity: SecureFileIdentity?
    ) -> LoadResult {
        let warning = SessionRecoveryWarning(
            kind: .archivedSnapshot(
                archivedSnapshotURL: archiveResult.url,
                archiveError: archiveResult.error
            ),
            protectedSnapshotIdentity: protectedSnapshotIdentity
        )
        blockedRecoveryWarningID = warning.id
        return LoadResult(
            store: SessionStore(),
            recoveryWarning: warning
        )
    }

    private static func conflictedLoad(
        store: SessionStore,
        openedData: Data,
        protectedSnapshotIdentity: SecureFileIdentity?
    ) -> LoadResult {
        let archiveResult = archiveConflictedSnapshot(openedData)
        return conflictedLoad(
            store: store,
            archiveResult: archiveResult,
            protectedSnapshotIdentity: protectedSnapshotIdentity
        )
    }

    private static func conflictedLoad(
        store: SessionStore,
        archiveResult: (url: URL?, error: String?),
        protectedSnapshotIdentity: SecureFileIdentity?
    ) -> LoadResult {
        let warning = SessionRecoveryWarning(
            kind: .snapshotConflict(
                archivedSnapshotURL: archiveResult.url,
                archiveError: archiveResult.error
            ),
            protectedSnapshotIdentity: protectedSnapshotIdentity
        )
        blockedRecoveryWarningID = warning.id
        return LoadResult(store: store, recoveryWarning: warning)
    }

    nonisolated private static func archiveCorruptedSnapshot(
        _ originalData: Data,
        expectedIdentity: SecureFileIdentity?,
        afterValidation: () throws -> Void
    ) -> (url: URL?, error: String?) {
        let archiveURL = supportDirectoryURL.appending(
            path: "session-state.corrupted-\(archiveTimestamp())-\(UUID().uuidString.prefix(8)).json"
        )

        guard !FileManager.default.fileExists(atPath: archiveURL.path) else {
            let message = "refusing to archive session snapshot because destination exists"
            logger.error("\(message, privacy: .public)")
            return (nil, message)
        }

        do {
            try FileManager.default.createOwnerOnlyDirectory(at: supportDirectoryURL)
            try FileManager.default.setOwnerOnlyPermissions(onDirectoryAt: supportDirectoryURL)
            try FileManager.default.writeOwnerOnlyFile(
                at: archiveURL,
                contents: originalData
            )

            guard let expectedIdentity, snapshotPathMatches(expectedIdentity) else {
                let message = "session snapshot path changed after opening; archived read bytes and left replacement untouched"
                logger.error("\(message, privacy: .public)")
                pruneQuarantineArchives(prefix: "session-state.corrupted-")
                return (archiveURL, message)
            }

            try afterValidation()
            guard snapshotPathMatches(expectedIdentity) else {
                let message = "session snapshot path changed after validation; archived read bytes and left replacement untouched"
                logger.error("\(message, privacy: .public)")
                pruneQuarantineArchives(prefix: "session-state.corrupted-")
                return (archiveURL, message)
            }

            // Keep the live path in place. POSIX has no conditional unlink that
            // removes a directory entry only if it still names this descriptor;
            // a path-based remove after validation can delete a replacement.
            // The exact opened bytes are archived above, and the recovery
            // warning blocks the initial save until the user acknowledges it.
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
        _ originalData: Data,
        expectedIdentity: SecureFileIdentity?
    ) -> (url: URL?, error: String?) {
        guard let expectedIdentity, snapshotPathMatches(expectedIdentity) else {
            let message = "session snapshot path changed after opening; left replacement untouched"
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
            try FileManager.default.writeOwnerOnlyFile(
                at: archiveURL,
                contents: originalData
            )
            guard snapshotPathMatches(expectedIdentity) else {
                let message = "session snapshot path changed while archiving; archived read bytes and left replacement untouched"
                logger.error("\(message, privacy: .public)")
                pruneQuarantineArchives(prefix: "session-state.sanitized-")
                return (archiveURL, message)
            }
            logger.error("archived sanitized session snapshot to \(archiveURL.path, privacy: .public)")
            pruneQuarantineArchives(prefix: "session-state.sanitized-")
            return (archiveURL, nil)
        } catch {
            let message = error.localizedDescription
            logger.error("failed to archive sanitized session snapshot: \(message, privacy: .public)")
            return (nil, message)
        }
    }

    nonisolated private static func archiveConflictedSnapshot(
        _ openedData: Data
    ) -> (url: URL?, error: String?) {
        let archiveURL = supportDirectoryURL.appending(
            path: "session-state.conflict-\(archiveTimestamp())-\(UUID().uuidString.prefix(8)).json"
        )

        do {
            try FileManager.default.createOwnerOnlyDirectory(at: supportDirectoryURL)
            try FileManager.default.setOwnerOnlyPermissions(onDirectoryAt: supportDirectoryURL)
            try FileManager.default.writeOwnerOnlyFile(
                at: archiveURL,
                contents: openedData
            )
            logger.error("archived conflicted session snapshot to \(archiveURL.path, privacy: .public)")
            pruneQuarantineArchives(prefix: "session-state.conflict-")
            return (archiveURL, nil)
        } catch {
            let message = error.localizedDescription
            logger.error("failed to archive conflicted session snapshot: \(message, privacy: .public)")
            return (nil, message)
        }
    }

    nonisolated private static var snapshotPathExists: Bool {
        var status = stat()
        return lstat(snapshotURL.path, &status) == 0
    }

    nonisolated private static func snapshotPathMatches(
        _ expectedIdentity: SecureFileIdentity
    ) -> Bool {
        var status = stat()
        guard lstat(snapshotURL.path, &status) == 0 else {
            return false
        }
        return UInt64(status.st_dev) == expectedIdentity.device
            && UInt64(status.st_ino) == expectedIdentity.inode
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

    static func withTemporarySupportDirectoryAsync<T>(
        _ url: URL,
        operation: () async throws -> T
    ) async rethrows -> T {
        let previousEnvironment = readEnvironment()
        resetWriteState()
        writeEnvironment(Environment(supportDirectoryURL: url))
        defer {
            resetWriteState()
            writeEnvironment(previousEnvironment)
            resetWriteState()
        }
        return try await operation()
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
        blockedRecoveryWarningID = nil
    }

    nonisolated private static var snapshotURL: URL {
        supportDirectoryURL.appending(path: "session-state.json")
    }

    nonisolated static var supportDirectoryURL: URL {
        readEnvironment().supportDirectoryURL
    }
}
