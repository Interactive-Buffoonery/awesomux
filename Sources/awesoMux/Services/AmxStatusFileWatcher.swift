import AwesoMuxCore
import Darwin
import Foundation
import os

// MARK: - AmxStatusFileWatcher

/// Watches a per-attach amx status file for new lifecycle JSONL lines and emits
/// parsed `AmxStatusEvent` values to a callback.
///
/// The kqueue watch fd is opened with `O_EVTONLY | O_NOFOLLOW | O_CLOEXEC` and
/// validated (regular file, owned by effective UID) before arming. Each drain
/// opens a fresh `O_RDONLY | O_NOFOLLOW | O_CLOEXEC` read handle via
/// `AgentRuntimeEventFile.openForReading(at:)`. Both validation paths check
/// file type and owner; mode bits are enforced at creation time —
/// `AmxBackend.makeStatusChannel(for:)` pre-creates the status file through
/// `AgentRuntimeEventFile.prepare(at:)` (`O_CREAT | O_EXCL`, `fchmod 0600`)
/// before the attach command runs, so the file always exists (and is owner-only)
/// by the time this watcher arms.
///
/// A `DispatchSourceFileSystemObject` (kqueue vnode watch) delivers change
/// notifications; new bytes are read by offset so lines that arrive across
/// multiple kqueue fires are only parsed once the terminating newline arrives.
///
/// The pure `consume(_:pendingTail:expectedToken:)` static method is the
/// testable core: it handles the byte → complete-lines → events pipeline
/// without touching the filesystem or kqueue.
@MainActor
final class AmxStatusFileWatcher {

    // MARK: - Private state (all @MainActor)

    private let channel: AmxStatusChannel
    private let onEvents: @MainActor ([AmxStatusEvent]) -> Void

    /// Byte offset of the next unread byte in the file.
    private var offset: UInt64 = 0
    /// Bytes after the last newline in the most recent read — a partial line
    /// not yet terminated. Prepended to the next read's data in `consume`.
    private var pendingTail: Data = Data()
    /// The live kqueue-backed vnode watch. Nil before `start()` or after `stop()`.
    private var source: DispatchSourceFileSystemObject?
    /// True when the source has been resumed and not yet suspended/cancelled.
    private var isSourceResumed: Bool = false

    private static let logger = Logger(subsystem: "awesomux.amx", category: "status-file-watcher")

    // MARK: - Init

    /// - Parameters:
    ///   - channel: Per-attach descriptor carrying `fileURL` and the forgery token.
    ///   - onEvents: Called on the main actor whenever one or more complete events
    ///     are decoded from new file data. Never called with an empty array.
    init(channel: AmxStatusChannel, onEvents: @escaping @MainActor ([AmxStatusEvent]) -> Void) {
        self.channel = channel
        self.onEvents = onEvents
    }

    /// Backstop teardown. Normal path is `stop()`. `isolated deinit` runs on
    /// the MainActor so it can safely touch `source` and `isSourceResumed`,
    /// matching the pattern in `AgentRuntimeEventBridge`. Without this, dropping
    /// the last reference without calling `stop()` leaks the evtFD (cancel
    /// handler never runs) and may trap in libdispatch if the source is
    /// inadvertently in a suspended state.
    isolated deinit {
        tearDownSource()
    }

    // MARK: - Lifecycle

    /// Open and validate the status file, read any bytes already present, then
    /// arm a kqueue watch for future writes. Safe to call multiple times
    /// (subsequent calls are no-ops if the source is already live).
    ///
    /// If the file is missing or fails validation the method returns without
    /// error — the bridge degrades to the existing exit path in that case.
    func start() {
        guard source == nil else {
            // Already started — idempotent.
            return
        }
        armSource()
    }

    /// True once `start()` has armed a live vnode watch. The exit handler gates
    /// the status-driven decision on this (not merely on a non-nil channel): if
    /// arming silently failed — a missing or unvalidatable status file — the
    /// status feed never delivers, so the handler must fall back to the legacy
    /// exitCode + `amx list` probe instead of mis-deciding off an empty feed.
    var isArmed: Bool { source != nil }

    /// Tear down the kqueue watch. Idempotent; safe to call from the surface-
    /// disposal path or after `start()` was a no-op.
    func stop() {
        tearDownSource()
        offset = 0
        pendingTail = Data()
        // Remove this attach's per-attach status file. Each attach mints a
        // unique file (token in the name), so once its watch is torn down the
        // file is dead — without this, respawns/re-attaches accumulate orphaned
        // `*.status.jsonl` files under the runtime dir for the app's lifetime.
        // The amx writer holds its own fd, so unlinking the path here is safe
        // even if it's mid-write (writes land on the now-unlinked inode).
        try? FileManager.default.removeItem(at: channel.fileURL)
    }

    /// Synchronously read any bytes that were written but whose kqueue callback
    /// has not fired yet. Used by command-finished supervision before it tears
    /// down the watcher and decides whether the pane should close or respawn.
    func drainPendingEvents() {
        drain()
    }

    // MARK: - Pure consume() core

    /// Maximum size of a pending tail (bytes awaiting a newline).
    /// The Zig writer caps a status line at 2048 bytes; 8192 is generous headroom
    /// and still bounds memory against a newline-less garbage stream (crash data, etc.).
    nonisolated private static let maxTailBytes = 8192

    /// Extract complete JSONL lines from `newBytes` + `pendingTail`, parse them
    /// into `AmxStatusEvent` values, and return the remaining partial line.
    ///
    /// "Complete" means terminated by a `0x0A` (LF) byte. Bytes after the last
    /// newline are returned as `remainingTail` — they form the start of a line
    /// that has not been fully written yet (kqueue can fire mid-write) and must
    /// be prepended to the next call's `newBytes`.
    ///
    /// If the computed `remainingTail` exceeds `maxTailBytes` and contains no newline,
    /// it is dropped (returned as empty Data) to bound memory against garbage input.
    /// This protects against a daemon that crashes or emits bytes with no line terminator.
    ///
    /// This function is `static` so tests can call it directly without
    /// constructing a watcher or touching the filesystem.
    ///
    /// - Parameters:
    ///   - newBytes: Freshly read bytes from the status file.
    ///   - pendingTail: Partial-line bytes carried over from the previous call.
    ///   - expectedToken: Forgery-guard token; lines with a different token are
    ///     dropped by `AmxStatusEvent.parseLines`.
    /// - Returns: A tuple of decoded events and the new `remainingTail`.
    nonisolated static func consume(
        _ newBytes: Data,
        pendingTail: Data,
        expectedToken: String
    ) -> (events: [AmxStatusEvent], remainingTail: Data) {
        // Combine accumulated tail with fresh bytes into one buffer.
        // Fast path: avoid the Data copy when the tail is empty (happy path).
        let buffer: Data
        if pendingTail.isEmpty {
            buffer = newBytes
        } else {
            var combined = pendingTail
            combined.append(newBytes)
            buffer = combined
        }

        guard !buffer.isEmpty else {
            return (events: [], remainingTail: Data())
        }

        // Find the index immediately AFTER the last newline (0x0A).
        // Everything up to (not including) that index is "complete" text;
        // everything from that index onward is the new partial-line tail.
        guard let lastNewlineIndex = buffer.lastIndex(of: 0x0A) else {
            // No newline anywhere — the entire buffer is a partial line.
            // Bound memory: if it's grown past maxTailBytes, drop it.
            if buffer.count > maxTailBytes {
                // Garbage input (no newline in 8KB+) — don't retain.
                return (events: [], remainingTail: Data())
            }
            return (events: [], remainingTail: buffer)
        }

        let completeEnd = buffer.index(after: lastNewlineIndex)
        let completeSlice = buffer[buffer.startIndex..<completeEnd]
        let newTail = buffer[completeEnd...]

        guard let completeString = String(data: Data(completeSlice), encoding: .utf8) else {
            // Malformed UTF-8 — discard the slice and keep the tail.
            // Apply the same bound: if tail exceeds maxTailBytes, drop it.
            if newTail.count > maxTailBytes {
                return (events: [], remainingTail: Data())
            }
            return (events: [], remainingTail: Data(newTail))
        }

        let events = AmxStatusEvent.parseLines(completeString, expectedToken: expectedToken)
        // Apply the same bound to the new tail (though it should be small after a newline).
        let boundedTail = newTail.count > maxTailBytes ? Data() : Data(newTail)
        return (events: events, remainingTail: boundedTail)
    }

    // MARK: - Internal (@MainActor)

    /// Open the file with `O_EVTONLY | O_NOFOLLOW | O_CLOEXEC`, validate it,
    /// do an initial drain from offset 0, then arm the vnode watch.
    private func armSource() {
        // Validate the file before arming to avoid watching a symlink or a
        // file we don't own. O_EVTONLY is for the kqueue watch; actual reads
        // use a freshly validated O_RDONLY handle in `drain()`.
        let evtFD = open(channel.fileURL.path, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC)
        guard evtFD >= 0 else {
            Self.logger.info(
                "amx status file not yet present (or open failed): \(self.channel.fileURL.path, privacy: .public) errno=\(errno, privacy: .public)"
            )
            return
        }

        var st = stat()
        guard fstat(evtFD, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFREG,
              st.st_uid == geteuid()
        else {
            Self.logger.error(
                "amx status file failed descriptor validation: \(self.channel.fileURL.path, privacy: .public)"
            )
            close(evtFD)
            return
        }

        let newSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: evtFD,
            eventMask: [.write, .extend, .delete, .rename],
            queue: .main
        )

        // Cancel handler closes the O_EVTONLY fd. Set BEFORE resume so the
        // fd always has a guaranteed exit even if resume throws.
        newSource.setCancelHandler {
            close(evtFD)
        }

        newSource.setEventHandler { [weak self, weak newSource] in
            guard let self, let newSource else { return }
            let mask = newSource.data
            MainActor.assumeIsolated {
                // Pin to this source generation: if armSource() is called again
                // (e.g., after a rename/delete) the stored source is replaced;
                // stale fires from the old source must be no-ops.
                guard self.source === newSource else { return }
                self.handleSourceEvent(mask: mask)
            }
        }

        source = newSource
        newSource.resume()
        isSourceResumed = true

        // Initial drain: pick up any bytes already written before we armed.
        drain()
    }

    private func handleSourceEvent(mask: DispatchSource.FileSystemEvent) {
        if mask.contains(.delete) || mask.contains(.rename) {
            // The status file was rotated out from under us (unusual for an
            // append-only lifecycle file, but tolerate it gracefully by
            // stopping — the attach is already over if the file is gone).
            Self.logger.notice(
                "amx status file rotated/deleted; stopping watcher: \(self.channel.fileURL.path, privacy: .public)"
            )
            stop()
            return
        }
        drain()
    }

    /// Read new bytes from the validated file starting at `offset`, pass them
    /// through `consume`, advance `offset` by the consumed byte count, keep the
    /// tail for the next call, and forward any decoded events to `onEvents`.
    private func drain() {
        guard let readHandle = AgentRuntimeEventFile.openForReading(at: channel.fileURL) else {
            // File missing or validation failed — degrade silently.
            return
        }

        // Guard against truncation (file replaced with a smaller one). A status
        // file is append-only and uniquely named per attach, so a shrink is
        // anomalous — but do NOT reset to 0 and re-read: that re-emits
        // already-consumed `attached`/`session-end` lines, and a re-emitted
        // session-end would spuriously re-drive exit supervision (a phantom
        // respawn). Skip to the new EOF so only genuinely new bytes are read.
        if readHandle.size < offset {
            offset = readHandle.size
            pendingTail = Data()
        }

        guard readHandle.size > offset else {
            // Nothing new to read.
            return
        }

        guard let newBytes = readHandle.readData(from: offset) else {
            Self.logger.error(
                "read failed for amx status file at offset \(self.offset, privacy: .public): \(self.channel.fileURL.path, privacy: .public)"
            )
            return
        }

        guard !newBytes.isEmpty else {
            return
        }

        // Advance offset by the number of bytes we just read.
        offset += UInt64(newBytes.count)

        let (events, newTail) = AmxStatusFileWatcher.consume(
            newBytes,
            pendingTail: pendingTail,
            expectedToken: channel.token
        )
        pendingTail = newTail

        if !events.isEmpty {
            onEvents(events)
        }
    }

    // MARK: - Teardown

    private func tearDownSource() {
        guard let src = source else {
            return
        }
        // A suspended source must be resumed before cancel so its cancel
        // handler (which closes the evtFD) actually runs. This watcher has
        // no suspend/resume path today (unlike AgentRuntimeEventBridge), so
        // this branch is currently unreachable — but it guards against
        // future refactors that defer resume() in armSource().
        if !isSourceResumed {
            src.resume()
        }
        src.cancel()
        source = nil
        isSourceResumed = false
    }
}
