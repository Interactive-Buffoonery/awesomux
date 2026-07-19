import AwesoMuxCore
import Foundation
import Observation

// MARK: - DocumentRevisionMonitor

/// Owns `DocumentRevisionIndicatorState` for one document group and detects
/// external edits to tabs the mounted `DocumentPaneView` cannot see (INT-782).
///
/// The mounted pane still owns the selected tab's watcher/reload/diff pipeline
/// unchanged — its diff must stay coupled to the reload that swaps content in
/// (see the load-bearing ordering note in `DocumentPaneView`). This monitor
/// covers everything that pipeline structurally misses:
///
/// - **Background tabs.** One group-lifetime watcher per unique standardized
///   file path, alive regardless of selection, so a selection change never
///   opens a watch gap. Events diff against the tab's *baseline* — the last
///   source the user actually saw — so successive background edits accumulate
///   into one honest count instead of diffing edit-to-edit.
/// - **The selection transition.** `reconcile(tab:)` re-reads the incoming
///   tab's file on selection so an edit that landed inside a watcher debounce
///   window still records before the remount silently adopts disk content.
///
/// Per-tab `lastSeenOnDisk` (distinct from the baseline, which deliberately
/// does not advance on background edits) deduplicates repeated watcher
/// callbacks for one write and gates announcements to genuine source
/// transitions. Per-path processing is FIFO-chained so a slow older read can
/// never commit over a newer one.
@MainActor
@Observable
final class DocumentRevisionMonitor {

    /// The single indicator store for the group; `DocumentGroupView` and the
    /// tab strip read and mutate it only through this monitor.
    private(set) var indicators = DocumentRevisionIndicatorState()

    /// Injection seams for tests; production uses the shared self-write
    /// registry and the VoiceOver announcer.
    @ObservationIgnored var announce: (String) -> Void = {
        TerminalAccessibilityAnnouncer.announce($0)
    }
    @ObservationIgnored var selfWriteContext: (URL, String) -> MarkdownSelfWriteContext? = {
        DocumentPaneView.selfWriteRegistry.context(fileURL: $0, onDiskSource: $1)
    }

    private struct Entry {
        let fileURL: URL
        let sourcePath: String
        let epoch: Int
        /// Last source the user saw (render completion or self-write). `nil`
        /// until a first observation exists — a first read never indicates.
        var baseline: String?
        /// Last on-disk source this monitor processed for the tab. Separate
        /// from `baseline` so repeated callbacks for one write dedupe while
        /// the diff still accumulates from what the user last saw.
        var lastSeenOnDisk: String?
    }

    /// A reconcile snapshots its target's baseline synchronously at selection
    /// time: the remounting pane's render advances the entry's baseline
    /// concurrently, and diffing against the captured value keeps the
    /// debounce-gap handoff deterministic regardless of which finishes first.
    private struct ReconcileRequest {
        let tabID: DocumentPane.ID
        let epoch: Int
        let capturedBaseline: String?
    }

    @ObservationIgnored private var entries: [DocumentPane.ID: Entry] = [:]
    @ObservationIgnored private var watchers: [String: DocumentFileWatcher] = [:]
    @ObservationIgnored private var pathTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var lastAnnouncedSource: [String: String] = [:]
    /// Generation of the most recent monitor-recorded indicator per tab, so
    /// `recordSelected` can recognize (and not re-announce) the mounted pane
    /// re-reporting the same revision a reconcile just recorded.
    @ObservationIgnored private var monitorRecordedGenerations: [DocumentPane.ID: Int] = [:]
    @ObservationIgnored private var tabs: [DocumentPane] = []
    @ObservationIgnored private var selectedTabID: DocumentPane.ID?
    @ObservationIgnored private var epochCounter = 0
    /// Bumped by `stopAll()`. In-flight processing chains from before the stop
    /// carry the old value and abort at their next commit point, so a stopped
    /// monitor that quickly re-syncs cannot receive stale commits.
    @ObservationIgnored private var runEpoch = 0

    // MARK: - Indicator passthroughs

    func indicator(for tab: DocumentPane) -> DocumentRevisionIndicatorState.Indicator? {
        indicators.indicator(for: tab)
    }

    /// Records a diff produced by the mounted pane's own pipeline and
    /// announces it — the selected-tab path, unchanged from before INT-782,
    /// except that re-reporting the identical revision a reconcile just
    /// recorded refreshes the indicator without speaking it twice.
    func recordSelected(_ revision: LineDiffCount.ExternalEdit, for tab: DocumentPane) {
        let monitorGeneration = monitorRecordedGenerations.removeValue(forKey: tab.id)
        let duplicatesMonitorRecord =
            monitorGeneration != nil
            && indicators.indicator(for: tab).map {
                $0.generation == monitorGeneration && $0.revision == revision
            } == true
        indicators.record(revision, for: tab)
        guard !duplicatesMonitorRecord else { return }
        announce(revision.accessibilityAnnouncement(documentTitle: tab.title))
    }

    func expand(for tab: DocumentPane) {
        indicators.expand(for: tab)
    }

    func collapse(for tab: DocumentPane) {
        indicators.collapse(for: tab)
    }

    func dismiss(for tab: DocumentPane) {
        indicators.dismiss(for: tab)
    }

    func recordActiveViewingTime(_ duration: Duration, for tab: DocumentPane, generation: Int) {
        indicators.recordActiveViewingTime(duration, for: tab, generation: generation)
    }

    func remainingExpandedTime(of total: Duration, for tab: DocumentPane) -> Duration? {
        indicators.remainingExpandedTime(of: total, for: tab)
    }

    // MARK: - Lifecycle

    /// Reconciles entries and watchers with the group's current tabs. Called
    /// on group-view appearance (a restored multi-tab group needs background
    /// watchers before any group mutation) and on every group change.
    func sync(tabs: [DocumentPane], selectedTabID: DocumentPane.ID?, cachedSource: (DocumentPane) -> String?) {
        self.tabs = tabs
        self.selectedTabID = selectedTabID

        indicators.prune(keeping: tabs)

        let currentPaths = Dictionary(
            tabs.map { ($0.id, $0.fileURL.standardizedFileURL.path) },
            uniquingKeysWith: { first, _ in first }
        )
        entries = entries.filter { id, entry in currentPaths[id] == entry.sourcePath }
        monitorRecordedGenerations = monitorRecordedGenerations.filter { id, _ in
            entries[id] != nil
        }

        for tab in tabs where entries[tab.id] == nil {
            epochCounter += 1
            let cached = cachedSource(tab)
            let entry = Entry(
                fileURL: tab.fileURL,
                sourcePath: tab.fileURL.standardizedFileURL.path,
                epoch: epochCounter,
                baseline: cached,
                lastSeenOnDisk: cached
            )
            entries[tab.id] = entry
            if entry.baseline == nil {
                seedBaseline(tabID: tab.id, fileURL: tab.fileURL, epoch: entry.epoch)
            }
        }

        let neededPaths = Set(entries.values.map(\.sourcePath))
        for path in watchers.keys where !neededPaths.contains(path) {
            watchers[path]?.stop()
            watchers[path] = nil
            pathTasks[path]?.cancel()
            pathTasks[path] = nil
            lastAnnouncedSource[path] = nil
        }
        for (id, entry) in entries where watchers[entry.sourcePath] == nil {
            let path = entry.sourcePath
            let watcher = DocumentFileWatcher(url: tabs.first { $0.id == id }?.fileURL ?? entry.fileURL) {
                [weak self] in
                self?.enqueueProcess(path: path)
            }
            watcher.start()
            watchers[path] = watcher
        }
    }

    /// Advances the tab's baseline when the mounted pane completes a load:
    /// whatever rendered is now what the user has seen. Also marks the source
    /// as observed so a watcher wobble carrying identical content cannot
    /// reprocess it (and, via the return-to-baseline rule, dismiss a
    /// legitimately recorded indicator).
    func noteRenderCompleted(source: String?, for tab: DocumentPane) {
        guard let source else { return }
        let path = tab.fileURL.standardizedFileURL.path
        if var entry = entries[tab.id], entry.sourcePath == path {
            entry.baseline = source
            entry.lastSeenOnDisk = source
            entries[tab.id] = entry
        } else {
            epochCounter += 1
            entries[tab.id] = Entry(
                fileURL: tab.fileURL,
                sourcePath: path,
                epoch: epochCounter,
                baseline: source,
                lastSeenOnDisk: source
            )
        }
    }

    /// Covers the selection transition: the incoming tab's file is re-read and
    /// diffed against the baseline captured right now, so an edit that fell
    /// into a watcher debounce window still records instead of the remount
    /// silently adopting disk content — even when the remounting pane's render
    /// completes (and advances the live baseline) before the read commits.
    func reconcile(tab: DocumentPane) {
        let path = tab.fileURL.standardizedFileURL.path
        guard let entry = entries[tab.id], entry.sourcePath == path else { return }
        enqueueProcess(
            path: path,
            reconcile: ReconcileRequest(
                tabID: tab.id,
                epoch: entry.epoch,
                capturedBaseline: entry.baseline
            )
        )
    }

    func stopAll() {
        runEpoch += 1
        for watcher in watchers.values {
            watcher.stop()
        }
        watchers = [:]
        for task in pathTasks.values {
            task.cancel()
        }
        pathTasks = [:]
        // A remounted viewer starts with a clean announce slate; suppressing
        // by pre-stop source would silently swallow a genuine post-remount
        // transition that happens to match an old announcement.
        lastAnnouncedSource = [:]
    }

    // MARK: - Event processing

    private func seedBaseline(tabID: DocumentPane.ID, fileURL: URL, epoch: Int) {
        Task { @MainActor [weak self] in
            let source = await Task.detached(priority: .utility) {
                DocumentLoader.readSnapshot(fileURL)?.source
            }.value
            guard let self, let source,
                var entry = self.entries[tabID],
                entry.epoch == epoch,
                entry.baseline == nil
            else { return }
            entry.baseline = source
            entry.lastSeenOnDisk = source
            self.entries[tabID] = entry
        }
    }

    /// FIFO-chains processing per path: rapid edits produce ordered commits,
    /// so an older read can never overwrite a newer result. `runEpoch` is
    /// captured here because `stopAll()` clears the chain — a task already
    /// past its `await previous` would otherwise outlive the stop.
    private func enqueueProcess(path: String, reconcile: ReconcileRequest? = nil) {
        let previous = pathTasks[path]
        let expectedRunEpoch = runEpoch
        pathTasks[path] = Task { @MainActor [weak self] in
            await previous?.value
            guard !Task.isCancelled, let self, self.runEpoch == expectedRunEpoch else { return }
            await self.process(path: path, reconcile: reconcile, expectedRunEpoch: expectedRunEpoch)
        }
    }

    private func process(path: String, reconcile: ReconcileRequest?, expectedRunEpoch: Int) async {
        // The selected tab's pipeline owns its own diff; the monitor only
        // targets it when explicitly reconciling a selection transition.
        // Iterating `tabs` (not the entries dictionary) keeps target order —
        // and therefore the announced title for same-file tabs — stable.
        let targetIDs = tabs.compactMap { tab -> DocumentPane.ID? in
            guard let entry = entries[tab.id], entry.sourcePath == path else { return nil }
            guard tab.id != selectedTabID || tab.id == reconcile?.tabID else { return nil }
            return tab.id
        }
        guard !targetIDs.isEmpty,
            let fileURL = entries[targetIDs[0]]?.fileURL
        else { return }

        let source = await Task.detached(priority: .userInitiated) {
            DocumentLoader.readSnapshot(fileURL)?.source
        }.value
        guard runEpoch == expectedRunEpoch else { return }
        // Deleted or unreadable content never indicates; the next readable
        // event diffs against the untouched baseline.
        guard let source else { return }

        let selfWrite = selfWriteContext(fileURL, source)
        if selfWrite?.isSelfWrite == true {
            // An awesoMux-authored write is content the user effectively
            // authored; advance baselines so it never counts in a later diff.
            for id in targetIDs {
                advance(tabID: id, path: path, to: source)
            }
            return
        }

        struct Pending {
            let tabID: DocumentPane.ID
            let epoch: Int
            let old: String
        }
        var pending: [Pending] = []
        for id in targetIDs {
            guard let entry = entries[id] else { continue }
            // A reconcile bypasses the last-seen dedup and diffs against the
            // baseline captured at selection time: the pane's render may have
            // already advanced the live entry, and skipping here would let the
            // remount silently adopt the very edit reconcile exists to catch.
            let isReconcileTarget = reconcile?.tabID == id && reconcile?.epoch == entry.epoch
            guard isReconcileTarget || entry.lastSeenOnDisk != source else { continue }
            // A coalesced self-write + external edit diffs from the user's own
            // just-written source, matching the mounted pane's semantics.
            let baseline = isReconcileTarget ? reconcile?.capturedBaseline : entry.baseline
            guard let old = selfWrite?.source ?? baseline else {
                // First observation of this file for the tab: becomes the
                // baseline, never an indicator.
                advance(tabID: id, path: path, to: source)
                continue
            }
            pending.append(Pending(tabID: id, epoch: entry.epoch, old: old))
        }
        guard !pending.isEmpty else { return }

        // Same-file tabs usually share a baseline; diff each unique old
        // source once instead of once per tab.
        let uniqueOlds = Array(Set(pending.map(\.old)))
        let diffByOld = await Task.detached(priority: .userInitiated) {
            Dictionary(
                uniqueKeysWithValues: uniqueOlds.map {
                    ($0, LineDiffCount.forExternalEdit(old: $0, new: source, isSelfWrite: false))
                }
            )
        }.value
        guard runEpoch == expectedRunEpoch else { return }

        var recordedTab: DocumentPane?
        for item in pending {
            // Commit-time validation: the tab must still exist with the same
            // pinned path and epoch — a stale async result for a closed or
            // in-place-replaced tab must not resurrect state.
            guard let entry = entries[item.tabID],
                entry.epoch == item.epoch,
                entry.sourcePath == path,
                let tab = tabs.first(where: {
                    $0.id == item.tabID && $0.fileURL.standardizedFileURL.path == path
                })
            else { continue }
            if let diff = diffByOld[item.old] ?? nil {
                indicators.record(diff, for: tab)
                monitorRecordedGenerations[tab.id] = indicators.indicator(for: tab)?.generation
                if recordedTab == nil || item.tabID == reconcile?.tabID {
                    recordedTab = tab
                }
            } else if source == item.old {
                // Content returned exactly to what the user last saw; a stale
                // marker would claim changes that no longer exist. Clearing
                // the announce dedup lets a later re-edit back to the
                // previously announced content speak again.
                indicators.dismiss(for: tab)
                lastAnnouncedSource[path] = nil
            }
            advance(tabID: item.tabID, path: path, to: source, keepBaseline: true)
        }

        // One announcement per genuine source transition per file. When the
        // same file is also the selected tab (a watcher event, not a
        // reconcile), the mounted pane's own pipeline announces instead.
        let selectedPath =
            selectedTabID
            .flatMap { id in tabs.first { $0.id == id } }?
            .fileURL.standardizedFileURL.path
        if let recordedTab,
            reconcile != nil || path != selectedPath,
            lastAnnouncedSource[path] != source,
            let indicator = indicators.indicator(for: recordedTab)
        {
            lastAnnouncedSource[path] = source
            announce(indicator.revision.accessibilityAnnouncement(documentTitle: recordedTab.title))
        }
    }

    private func advance(tabID: DocumentPane.ID, path: String, to source: String, keepBaseline: Bool = false) {
        guard var entry = entries[tabID], entry.sourcePath == path else { return }
        if !keepBaseline {
            entry.baseline = source
        }
        entry.lastSeenOnDisk = source
        entries[tabID] = entry
    }
}
