import Foundation
import Observation
import os

/// Persisted local analytics event log plus the app-local anonymous
/// distinct id (ADR-0008: random UUID, stored only for analytics, reset
/// when analytics state is deleted).
///
/// Layout under the profile support directory:
///   analytics/events.jsonl   one `AnalyticsLogEntry` JSON object per line
///   analytics/distinct_id    bare UUID string
///
/// When `retainToDisk` is false (`analytics.retain_local_event_log`),
/// entries stay in memory for the running session and nothing is written.
///
/// `entries` is main-actor state for the diagnostics UI; all
/// events.jsonl I/O runs on a serial background queue because capture
/// sites sit on the terminal event path and must never wait on the disk.
@MainActor
@Observable
final class AnalyticsEventLogStore {
    private struct LoadResult: Sendable {
        let entries: [AnalyticsLogEntry]
        let diskMatchesEntries: Bool
        let retainedToDisk: Bool
    }

    static let maximumEntries = 500
    static let retentionDays = 30
    static let trimBatch = 50
    /// Far above anything the store writes (500 short JSONL lines); a
    /// larger file is not ours to parse and must not balloon memory.
    static let maximumFileBytes = 4 * 1024 * 1024

    private(set) var entries: [AnalyticsLogEntry] = []

    @ObservationIgnored var retainToDisk: () -> Bool
    @ObservationIgnored private let directoryURL: URL
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var hasLoaded = false
    @ObservationIgnored private var isLoading = false
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var loadWaiters: [CheckedContinuation<Void, Never>] = []
    /// False whenever the on-disk log may disagree with `entries` (retain
    /// was off for a span, a load failed, or rejected lines were skipped):
    /// the next retained append then rewrites the whole file instead of
    /// appending, so disk converges back to what the user saw.
    @ObservationIgnored private(set) var diskMatchesEntries = true
    @ObservationIgnored private let ioQueue = DispatchQueue(
        label: "awesomux.analytics.event-log-io", qos: .utility
    )
    @ObservationIgnored private let logger = Logger(
        subsystem: "awesomux.analytics", category: "event-log"
    )

    private var eventsURL: URL {
        directoryURL.appending(path: "events.jsonl")
    }

    private var distinctIDURL: URL {
        directoryURL.appending(path: "distinct_id")
    }

    init(
        rootDirectoryURL: URL = AppRuntimeProfile.current.supportDirectoryURL,
        retainToDisk: @escaping () -> Bool = { true },
        now: @escaping () -> Date = Date.init
    ) {
        self.directoryURL = rootDirectoryURL.appending(path: "analytics", directoryHint: .isDirectory)
        self.retainToDisk = retainToDisk
        self.now = now
    }

    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        await withCheckedContinuation { continuation in
            loadWaiters.append(continuation)
            startLoadingIfNeeded()
        }
    }

    /// Applies a disabled-retention setting without decoding the ledger on the
    /// main actor. Removal is ordered on the same queue as writes, so toggling
    /// retention back on cannot race a later full-ledger rewrite.
    func reconcileRetention() {
        guard !retainToDisk() else { return }
        loadGeneration += 1
        hasLoaded = true
        diskMatchesEntries = false
        let eventsURL = eventsURL
        let logger = logger
        ioQueue.async {
            if !Self.removeIfPresent(eventsURL) {
                logger.error("failed to remove analytics event log while retention is disabled")
            }
        }
    }

    func append(_ entry: AnalyticsLogEntry) {
        guard entry.provider == "posthog",
            entry.schemaVersion == analyticsSchemaVersion,
            entry.consentLevel != .off,
            entry.properties.allSatisfy({
                AnalyticsSanitizer.isShapeValid($0.value, for: $0.key)
            })
        else {
            logger.error("refusing analytics log entry that did not pass final privacy validation")
            return
        }

        startLoadingIfNeeded()
        entries.append(entry)
        let pruned = prune()
        guard retainToDisk() else {
            diskMatchesEntries = false
            return
        }
        if pruned || !diskMatchesEntries {
            scheduleRewrite()
        } else {
            scheduleAppendLine(entry)
        }
    }

    /// Deletes the on-disk log and the anonymous distinct id. The next
    /// opt-in starts from a fresh identity. This is synchronous because the
    /// user-facing deletion confirmation must not report success while files
    /// remain queued for removal.
    @discardableResult
    func deleteAll() -> Bool {
        loadGeneration += 1
        let eventsURL = eventsURL
        let eventsDeleted = ioQueue.sync {
            Self.removeIfPresent(eventsURL)
        }
        let distinctIDDeleted = Self.removeIfPresent(distinctIDURL)
        guard eventsDeleted, distinctIDDeleted else { return false }

        entries = []
        hasLoaded = true
        diskMatchesEntries = true
        return true
    }

    private func startLoadingIfNeeded() {
        guard !hasLoaded, !isLoading else { return }
        isLoading = true
        let generation = loadGeneration
        let eventsURL = eventsURL
        let directoryURL = directoryURL
        let retainToDisk = retainToDisk()
        let maximumFileBytes = Self.maximumFileBytes
        let logger = logger
        ioQueue.async {
            let result = Self.loadFromDisk(
                eventsURL: eventsURL,
                directoryURL: directoryURL,
                retainToDisk: retainToDisk,
                maximumFileBytes: maximumFileBytes,
                logger: logger
            )
            Task { @MainActor [weak self] in
                self?.finishLoading(result, generation: generation)
            }
        }
    }

    private func finishLoading(_ result: LoadResult, generation: Int) {
        isLoading = false
        if generation == loadGeneration, !hasLoaded {
            entries = result.entries + entries
            diskMatchesEntries =
                result.diskMatchesEntries
                && (result.retainedToDisk || entries.isEmpty)
            hasLoaded = true
            if prune() || !diskMatchesEntries {
                scheduleRewrite()
            }
        }
        let waiters = loadWaiters
        loadWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func distinctID() -> String {
        Self.clampDirectoryToOwnerOnly(directoryURL)
        Self.clampToOwnerOnly(distinctIDURL)
        do {
            let stored = try String(contentsOf: distinctIDURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if UUID(uuidString: stored) != nil { return stored }
            logger.notice("replacing invalid analytics distinct id file")
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // First use: mint below.
        } catch {
            // Present but unreadable: a transient I/O error must not rotate
            // the durable identity. Use a throwaway id for this call only.
            logger.error("analytics distinct id unreadable, not rotating: \(error)")
            return UUID().uuidString
        }
        let fresh = UUID().uuidString
        Self.ensureDirectory(directoryURL)
        do {
            try Data(fresh.utf8).write(to: distinctIDURL, options: .atomic)
            Self.clampToOwnerOnly(distinctIDURL)
        } catch {
            logger.error("failed to persist analytics distinct id: \(error)")
        }
        return fresh
    }

    /// Test seam: blocks until every scheduled disk write has landed.
    func waitForPendingWrites() {
        ioQueue.sync {}
    }

    @discardableResult
    private func prune() -> Bool {
        let cutoff = now().addingTimeInterval(-TimeInterval(Self.retentionDays) * 86_400)
        var kept = entries.filter { $0.timestamp >= cutoff }
        if kept.count > Self.maximumEntries {
            // Trim in batches so a full log does not degenerate into a
            // whole-file rewrite on every single append at the cap.
            kept.removeFirst(kept.count - (Self.maximumEntries - Self.trimBatch))
        }
        guard kept.count != entries.count else { return false }
        entries = kept
        return true
    }

    private func scheduleAppendLine(_ entry: AnalyticsLogEntry) {
        let eventsURL = eventsURL
        let directoryURL = directoryURL
        let logger = logger
        ioQueue.async { [entries] in
            Self.appendLineToDisk(
                entry, fallback: entries,
                eventsURL: eventsURL, directoryURL: directoryURL, logger: logger
            )
        }
    }

    private func scheduleRewrite() {
        guard retainToDisk() else {
            diskMatchesEntries = false
            return
        }
        diskMatchesEntries = true
        let eventsURL = eventsURL
        let directoryURL = directoryURL
        let logger = logger
        ioQueue.async { [entries] in
            do {
                try Self.writeAll(entries, eventsURL: eventsURL, directoryURL: directoryURL)
            } catch {
                logger.error("failed to rewrite analytics event log: \(error)")
                Task { @MainActor [weak self] in
                    self?.diskMatchesEntries = false
                }
            }
        }
    }

    private nonisolated static func appendLineToDisk(
        _ entry: AnalyticsLogEntry,
        fallback entries: [AnalyticsLogEntry],
        eventsURL: URL,
        directoryURL: URL,
        logger: Logger
    ) {
        ensureDirectory(directoryURL)
        guard var data = try? makeEncoder().encode(entry) else { return }
        data.append(UInt8(ascii: "\n"))
        if let handle = try? FileHandle(forWritingTo: eventsURL) {
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try? handle.close()
            } catch {
                // Close before falling back to a full rewrite: the atomic
                // rename must not race this still-open descriptor, and the
                // handle's position is unknown after a partial failure anyway.
                try? handle.close()
                logger.error("failed to append analytics log entry: \(error)")
                do {
                    try writeAll(entries, eventsURL: eventsURL, directoryURL: directoryURL)
                } catch {
                    logger.error("failed to rewrite analytics event log: \(error)")
                }
            }
        } else {
            try? data.write(to: eventsURL, options: .atomic)
            clampToOwnerOnly(eventsURL)
        }
    }

    private nonisolated static func writeAll(
        _ entries: [AnalyticsLogEntry],
        eventsURL: URL,
        directoryURL: URL
    ) throws {
        ensureDirectory(directoryURL)
        let encoder = makeEncoder()
        let lines = entries.compactMap { entry -> String? in
            guard let data = try? encoder.encode(entry) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        let body = lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
        try Data(body.utf8).write(to: eventsURL, options: .atomic)
        clampToOwnerOnly(eventsURL)
    }

    private nonisolated static func loadFromDisk(
        eventsURL: URL,
        directoryURL: URL,
        retainToDisk: Bool,
        maximumFileBytes: Int,
        logger: Logger
    ) -> LoadResult {
        clampDirectoryToOwnerOnly(directoryURL)
        clampToOwnerOnly(eventsURL)
        guard retainToDisk else {
            let removed = removeIfPresent(eventsURL)
            if !removed {
                logger.error("failed to remove analytics event log while retention is disabled")
            }
            return LoadResult(
                entries: [], diskMatchesEntries: removed, retainedToDisk: false
            )
        }
        if let size = try? eventsURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
            size > maximumFileBytes
        {
            logger.error("analytics event log exceeds size cap; discarding")
            return LoadResult(
                entries: [],
                diskMatchesEntries: removeIfPresent(eventsURL),
                retainedToDisk: true
            )
        }
        let data: Data
        do {
            data = try Data(contentsOf: eventsURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return LoadResult(entries: [], diskMatchesEntries: true, retainedToDisk: true)
        } catch {
            // Unreadable is not absent: appending against unknown disk
            // contents could resurrect history the user believes deleted,
            // so the next retained append rewrites from memory instead.
            logger.error("analytics event log unreadable: \(error)")
            return LoadResult(entries: [], diskMatchesEntries: false, retainedToDisk: true)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return LoadResult(entries: [], diskMatchesEntries: false, retainedToDisk: true)
        }
        let decoder = makeDecoder()
        let lines = text.split(separator: "\n")
        let entries = lines.compactMap { line in
            try? decoder.decode(AnalyticsLogEntry.self, from: Data(line.utf8))
        }
        return LoadResult(
            entries: entries,
            diskMatchesEntries: entries.count == lines.count,
            retainedToDisk: true
        )
    }

    /// Owner-only permissions: the log is sanitized of content but still a
    /// behavioral timeline, and distinct_id is the durable analytics
    /// identity — neither belongs to other users on a shared machine.
    /// Weaker than ConfigFileStore's create-exclusive pattern: writes land
    /// at umask defaults for a moment before the clamp. INT-859 extracts a
    /// shared helper that closes that window here too.
    private nonisolated static func removeIfPresent(_ url: URL) -> Bool {
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return true
        } catch {
            return false
        }
    }

    private nonisolated static func ensureDirectory(_ url: URL) {
        try? FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        clampDirectoryToOwnerOnly(url)
    }

    private nonisolated static func clampDirectoryToOwnerOnly(_ url: URL) {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: url.path
        )
    }

    private nonisolated static func clampToOwnerOnly(_ url: URL) {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path
        )
    }

    private nonisolated static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private nonisolated static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
