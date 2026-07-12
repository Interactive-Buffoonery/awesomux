import AppKit
import AwesoMuxCore
import Darwin
import Foundation
import os

@MainActor
final class AgentRuntimeEventBridge {
    private static let maximumEventFileByteCount: UInt64 = 1 * 1024 * 1024
    private static let staleEventFileAge: TimeInterval = 24 * 60 * 60
    private static let sourceRetryBaseDelay = Duration.milliseconds(250)
    private static let sourceRetryMaximumDelay = Duration.seconds(30)
    private static let logger = Logger(subsystem: "awesomux.agent", category: "runtime-event-bridge")
    private let diagnosticEventHandler: (LocalDiagnosticEventInput) -> Void

    private final class Watch {
        let fileURL: URL
        let applyEvent: (AgentRuntimeEvent) -> Void
        var offset: UInt64
        var trailingFragment: Data
        var source: DispatchSourceFileSystemObject?
        var hasLoggedSourceFailure: Bool
        var needsDrainRetry: Bool
        var inode: ino_t

        init(fileURL: URL, applyEvent: @escaping (AgentRuntimeEvent) -> Void, offset: UInt64) {
            self.fileURL = fileURL
            self.applyEvent = applyEvent
            self.offset = offset
            self.trailingFragment = Data()
            self.source = nil
            self.hasLoggedSourceFailure = false
            self.needsDrainRetry = false
            self.inode = 0
        }
    }

    private var watches: [TerminalPane.ID: Watch] = [:]
    private var sourceRetryTask: Task<Void, Never>?
    private var sourceRetryAttempt = 0
    private var isAppActive: Bool = true
    private var activationObservers: [NSObjectProtocol] = []
    private let notificationCenter: NotificationCenter
    private let runtimeEventsDirectoryURLOverride: URL?

    init(
        notificationCenter: NotificationCenter = .default,
        initialIsAppActive: Bool? = nil,
        runtimeEventsDirectoryURL: URL? = nil,
        diagnosticEventHandler: @escaping (LocalDiagnosticEventInput) -> Void = { _ in }
    ) {
        self.notificationCenter = notificationCenter
        self.runtimeEventsDirectoryURLOverride = runtimeEventsDirectoryURL
        self.diagnosticEventHandler = diagnosticEventHandler
        sweepStaleEventFiles()
        observeActivationState(initialIsAppActive: initialIsAppActive)
    }

    /// Swift 6 `isolated deinit` so cleanup runs on the MainActor and can
    /// safely touch `watches` / `activationObservers`. Bridge is intended
    /// to live for the app's lifetime today, but tests and future
    /// per-window scopes need a real release contract.
    isolated deinit {
        for token in activationObservers {
            notificationCenter.removeObserver(token)
        }
        activationObservers.removeAll()
        sourceRetryTask?.cancel()
        sourceRetryTask = nil
        for watch in watches.values {
            tearDownSource(for: watch)
        }
        watches.removeAll()
    }

    func environment(
        sessionID: TerminalSession.ID,
        paneID: TerminalPane.ID,
        enabledFileDropSources: Set<AgentRuntimeSource>,
        applyEvent: @escaping (AgentRuntimeEvent) -> Void
    ) -> AgentRuntimeEnvironment {
        // Guard against double-installation: replacing a watch without
        // tearing down its dispatch source would orphan the source and leak
        // the FD owned by the cancel handler.
        if watches[paneID] != nil {
            stopWatching(paneID: paneID)
        }

        let fileURL = eventFileURL(for: paneID)
        touchEventFile(at: fileURL)

        let watch = Watch(
            fileURL: fileURL,
            applyEvent: applyEvent,
            offset: AgentRuntimeEventFile.openForReading(at: fileURL)?.size ?? 0
        )
        watches[paneID] = watch
        // If startSource fails the watch stays in `watches` with `source ==
        // nil` so the helper still writes to a real file at the advertised
        // path. A cancellable backoff retries source creation while activation
        // remains an immediate recovery edge, picking up buffered events in
        // either case. Without this a transient EMFILE / permission blip would
        // silence the pane and the previously-running helper would have
        // nowhere observable to write.
        startSource(for: paneID)

        return AgentRuntimeEnvironment(
            sessionID: sessionID,
            paneID: paneID,
            eventFileURL: fileURL,
            enabledFileDropSources: enabledFileDropSources
        )
    }

    func stopWatching(paneID: TerminalPane.ID) {
        guard let watch = watches.removeValue(forKey: paneID) else {
            return
        }
        tearDownSource(for: watch)
        deleteEventFile(at: watch.fileURL)
        cancelSourceRetryIfUnneeded()
    }

    func stopWatchingAll() {
        let snapshot = Array(watches.values)
        watches.removeAll()
        for watch in snapshot {
            tearDownSource(for: watch)
            deleteEventFile(at: watch.fileURL)
        }
        cancelSourceRetryIfUnneeded()
    }

    func drainRuntimeEventsForTesting(paneID: TerminalPane.ID) {
        poll(paneID: paneID)
    }

    // MARK: - Dispatch source lifecycle

    /// Open the event file with `O_EVTONLY | O_NOFOLLOW | O_CLOEXEC` and arm
    /// a kqueue-backed dispatch source on it. `O_EVTONLY` requests
    /// notifications without granting read or write access; actual reads use
    /// a separate `O_NOFOLLOW`-validated descriptor in `poll(paneID:)`.
    /// `O_NOFOLLOW` closes a same-UID symlink-attack window between
    /// `touchEventFile` and `open` — defense-in-depth even though the parent
    /// dir is 0700.
    /// `O_CLOEXEC` keeps the FD from leaking into child processes spawned
    /// by ghostty surfaces.
    ///
    /// Returns false on `open()` failure so the caller can decide whether
    /// to keep or drop the corresponding watch entry.
    @discardableResult
    private func startSource(for paneID: TerminalPane.ID) -> Bool {
        guard let watch = watches[paneID] else {
            return false
        }
        // Defensive: never stack two sources on the same watch.
        if watch.source != nil {
            tearDownSource(for: watch)
        }

        let fd = open(watch.fileURL.path, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            if shouldLogSourceFailure(for: watch) {
                Self.logger.error(
                    "failed to open event file for watching: \(watch.fileURL.path, privacy: .public) errno=\(errno, privacy: .public)"
                )
            }
            scheduleSourceRetry(for: paneID)
            return false
        }

        // Verify what we opened is actually a regular file at the expected
        // path, then capture its inode so resume / re-arm paths can detect
        // out-of-band rotation.
        var st = stat()
        guard fstat(fd, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFREG,
              st.st_uid == geteuid() else {
            if shouldLogSourceFailure(for: watch) {
                Self.logger.error(
                    "event file is not a regular file or fstat failed: \(watch.fileURL.path, privacy: .public)"
                )
            }
            close(fd)
            scheduleSourceRetry(for: paneID)
            return false
        }
        watch.inode = st.st_ino

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: DispatchQueue.main
        )

        // Set the cancel handler BEFORE anything that could early-return so
        // the FD always has a guaranteed exit. Cancel runs asynchronously on
        // the source's queue (.main) after `cancel()` is called and the
        // source has been resumed at least once.
        source.setCancelHandler {
            close(fd)
        }

        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            let mask = source.data
            MainActor.assumeIsolated {
                // Pin to this source generation. After a .delete/.rename
                // re-arm the watch's stored source is a new instance; a
                // stale fire from the old source must be a no-op.
                guard self.watches[paneID]?.source === source else { return }
                self.handleSourceEvent(paneID: paneID, mask: mask)
            }
        }

        watch.source = source
        watch.hasLoggedSourceFailure = false

        source.resume()
        poll(paneID: paneID)
        cancelSourceRetryIfUnneeded()
        return true
    }

    private func handleSourceEvent(
        paneID: TerminalPane.ID,
        mask: DispatchSource.FileSystemEvent
    ) {
        guard watches[paneID] != nil else {
            return
        }

        // The shipped helper truncates in place (see `recreateEventFile`), so
        // .delete / .rename only fire when something external rotates the
        // file out from under us. Drop the orphan FD and re-arm against the
        // current inode at the same path.
        if mask.contains(.delete) || mask.contains(.rename) {
            rebuildSource(for: paneID, resetOffset: true)
            return
        }

        poll(paneID: paneID)
    }

    /// Tear down + re-open the dispatch source against the file currently at
    /// `watch.fileURL`. Used after external rotation, after the truncate
    /// fallback, and when resume-time inode comparison detects a swap.
    private func rebuildSource(for paneID: TerminalPane.ID, resetOffset: Bool) {
        guard let watch = watches[paneID] else { return }
        tearDownSource(for: watch)
        touchEventFile(at: watch.fileURL)
        if resetOffset {
            watch.offset = 0
            watch.trailingFragment = Data()
        }
        startSource(for: paneID)
    }

    /// Tear down a watch's dispatch source. Sources are resumed immediately
    /// after creation, so cancel always reaches the FD-closing handler.
    private func tearDownSource(for watch: Watch) {
        guard let source = watch.source else {
            return
        }
        source.cancel()
        watch.source = nil
        watch.inode = 0
    }

    private func scheduleSourceRetry(for paneID: TerminalPane.ID) {
        guard let watch = watches[paneID],
              (watch.source == nil || watch.needsDrainRetry),
              sourceRetryTask == nil else {
            return
        }

        let exponent = min(sourceRetryAttempt, 7)
        let delay = min(
            Self.sourceRetryBaseDelay * (1 << exponent),
            Self.sourceRetryMaximumDelay
        )
        sourceRetryAttempt += 1
        sourceRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else {
                return
            }
            self.sourceRetryTask = nil
            let pendingPaneIDs = self.watches.compactMap { paneID, watch in
                watch.source == nil || watch.needsDrainRetry ? paneID : nil
            }
            for pendingPaneID in pendingPaneIDs {
                guard let watch = self.watches[pendingPaneID] else {
                    continue
                }
                if watch.source == nil {
                    self.touchEventFile(at: watch.fileURL, logFailure: false)
                    self.startSource(for: pendingPaneID)
                } else if watch.needsDrainRetry {
                    self.poll(paneID: pendingPaneID)
                }
            }
            if self.watches.values.allSatisfy({ $0.source != nil && !$0.needsDrainRetry }) {
                self.sourceRetryAttempt = 0
            } else if let pendingPaneID = self.watches.first(where: {
                $0.value.source == nil || $0.value.needsDrainRetry
            })?.key {
                self.scheduleSourceRetry(for: pendingPaneID)
            }
        }
    }

    private func cancelSourceRetryIfUnneeded() {
        guard watches.values.allSatisfy({ $0.source != nil && !$0.needsDrainRetry }) else { return }
        sourceRetryTask?.cancel()
        sourceRetryTask = nil
        sourceRetryAttempt = 0
    }

    private func shouldLogSourceFailure(for watch: Watch) -> Bool {
        guard !watch.hasLoggedSourceFailure else { return false }
        watch.hasLoggedSourceFailure = true
        return true
    }

    // MARK: - App activation

    private func observeActivationState(initialIsAppActive: Bool?) {
        // Register observers BEFORE sampling `isActive` so a transition that
        // fires between the sample and the addObserver call cannot leave us
        // stuck with stale state.
        let center = notificationCenter
        let resignToken = center.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applicationDidResignActive()
            }
        }
        let activeToken = center.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applicationDidBecomeActive()
            }
        }
        activationObservers = [resignToken, activeToken]

        isAppActive = initialIsAppActive ?? NSApplication.shared.isActive
    }

    private func applicationDidResignActive() {
        guard isAppActive else { return }
        isAppActive = false
    }

    private func applicationDidBecomeActive() {
        guard !isAppActive else { return }
        isAppActive = true
        for (paneID, watch) in watches {
            // Source-less watch: a prior startSource / rebuildSource failed
            // (transient EMFILE, permissions race, etc.). Retry now that
            // we're foregrounded so the pane doesn't stay silent forever.
            guard watch.source != nil else {
                rebuildSource(for: paneID, resetOffset: false)
                continue
            }
            // If the file was rotated (deleted + replaced) while inactive, the
            // source's FD may point at an orphan inode if kqueue coalesced the
            // delete. Compare inodes and rebuild if they differ; otherwise
            // drain any bytes not already delivered by the source.
            guard let currentInode = AgentRuntimeEventFile.openForReading(at: watch.fileURL)?.inode else {
                var pathState = stat()
                if lstat(watch.fileURL.path, &pathState) != 0 {
                    if errno == ENOENT {
                        rebuildSource(for: paneID, resetOffset: true)
                    }
                } else if pathState.st_ino != watch.inode {
                    rebuildSource(for: paneID, resetOffset: true)
                }
                continue
            }
            if currentInode != watch.inode {
                rebuildSource(for: paneID, resetOffset: true)
                continue
            }
            poll(paneID: paneID)
        }
    }

    // MARK: - Reading

    private func poll(paneID: TerminalPane.ID) {
        guard let watch = watches[paneID] else {
            return
        }

        guard let readHandle = AgentRuntimeEventFile.openForReading(at: watch.fileURL) else {
            diagnosticEventHandler(.runtimeEventFileUnavailable)
            watch.needsDrainRetry = true
            scheduleSourceRetry(for: paneID)
            return
        }
        watch.needsDrainRetry = false
        cancelSourceRetryIfUnneeded()

        let currentSize = readHandle.size
        if currentSize > Self.maximumEventFileByteCount {
            Self.logger.notice(
                "agent runtime event file exceeded cap (\(currentSize, privacy: .public) bytes); truncating"
            )
            diagnosticEventHandler(.runtimeEventsDropped)
            let inodeChanged = recreateEventFile(at: watch.fileURL)
            watch.offset = 0
            watch.trailingFragment = Data()
            if inodeChanged {
                // Fallback path (unlink+create) rotated the inode out from
                // under the dispatch source — re-arm against the new file.
                rebuildSource(for: paneID, resetOffset: true)
            }
            return
        }

        if currentSize < watch.offset {
            watch.offset = 0
            watch.trailingFragment = Data()
        }

        guard currentSize > watch.offset,
              let data = readHandle.readData(from: watch.offset) else {
            return
        }

        watch.offset += UInt64(data.count)
        let (lines, remainder) = AgentRuntimeEventLineSplitter.extractCompleteLines(
            from: data,
            trailingFragment: watch.trailingFragment
        )
        watch.trailingFragment = remainder

        var rejectedAnyLine = false
        for line in lines where !line.isEmpty {
            guard let event = AgentRuntimeEvent.parse(data: line) else {
                rejectedAnyLine = true
                continue
            }
            watch.applyEvent(event)
        }
        // Coalesce per drain so a hostile/malformed dump cannot MainActor-storm
        // the diagnostic recorder with one event per line.
        if rejectedAnyLine {
            diagnosticEventHandler(.runtimeEventRejected)
        }
    }

    private func eventFileURL(for paneID: TerminalPane.ID) -> URL {
        runtimeEventsDirectoryURL
            .appending(path: "\(paneID.uuidString).jsonl")
    }

    private var runtimeEventsDirectoryURL: URL {
        runtimeEventsDirectoryURLOverride
            ?? SessionPersistence.supportDirectoryURL
                .appending(path: "runtime-events", directoryHint: .isDirectory)
    }

    private func touchEventFile(at url: URL, logFailure: Bool = true) {
        guard AgentRuntimeEventFile.prepare(at: url) else {
            if logFailure {
                Self.logger.error(
                    "failed to prepare agent runtime event file safely: \(url.path, privacy: .public)"
                )
                diagnosticEventHandler(.runtimeEventFileUnavailable)
            }
            return
        }
    }

    /// Truncate the event file in place rather than unlink + recreate,
    /// so adapters that hold the file descriptor open across writes (the
    /// shipped helper opens per-write, but third-party adapters may not)
    /// keep writing to the same inode the bridge is watching. An
    /// unlink-and-create rotation would orphan their writes to a deleted
    /// inode and break the side-channel contract for compliant writers —
    /// and would also trip the .delete branch in `handleSourceEvent`.
    ///
    /// Returns true if the fallback path (unlink + create) ran, signalling
    /// the caller that the watching dispatch source must be re-armed.
    private func recreateEventFile(at url: URL) -> Bool {
        switch AgentRuntimeEventFile.truncate(at: url) {
        case .truncatedInPlace:
            return false
        case .rotationRequired:
            // Truncation could not validate our own file (missing, symlink
            // swapped in by a same-UID process, wrong owner, or a race).
            // Unlink + recreate from scratch and signal the caller to re-arm.
            deleteEventFile(at: url)
            touchEventFile(at: url)
            return true
        }
    }

    private func deleteEventFile(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Scan the runtime-events directory and delete files older than
    /// `staleEventFileAge`. Bounded by mtime so a second awesoMux process
    /// (worktree build, etc.) does not wipe the first process's live
    /// event files. The watch path keys files by paneID UUID so collision
    /// across processes is astronomically unlikely. Skips symlinks so a
    /// same-UID process can't plant a symlink with backdated mtime and
    /// trick the sweeper into unlinking the target.
    private func sweepStaleEventFiles() {
        let directoryURL = runtimeEventsDirectoryURL
        guard FileManager.default.fileExists(atPath: directoryURL.path) else {
            return
        }
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isSymbolicLinkKey, .isRegularFileKey]
        ) else {
            return
        }

        let cutoff = Date().addingTimeInterval(-Self.staleEventFileAge)
        for fileURL in files where fileURL.pathExtension == "jsonl" {
            let values = try? fileURL.resourceValues(
                forKeys: [.contentModificationDateKey, .isSymbolicLinkKey, .isRegularFileKey]
            )
            guard values?.isSymbolicLink != true,
                  values?.isRegularFile == true,
                  let mtime = values?.contentModificationDate,
                  mtime < cutoff else {
                continue
            }
            deleteEventFile(at: fileURL)
        }
    }
}
