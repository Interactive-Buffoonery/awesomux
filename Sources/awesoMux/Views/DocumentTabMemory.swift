import AwesoMuxCore
import Foundation

/// Session-memory for the document tab strip (INT-748 PR2): the last rendered
/// document, scroll anchor, and copy-mode state per open tab, held as `@State` by
/// `DocumentGroupView` and never persisted.
///
/// The render entries exist so switching back to a tab shows its content
/// immediately instead of remounting into a spinner while the whole TextKit
/// pipeline rebuilds — the seeded view still re-reads the file in the
/// background (its watcher was off while hidden) and swaps in changes.
///
/// Memory ceiling: one entry per open tab. A successful entry holds the
/// rendered runs and one source copy inside `RenderedDocument`; failures keep
/// only their small error details. The source is bounded by
/// `DocumentURLValidator.maxFileSizeBytes`, and entries drop when their tab
/// closes. ponytail: no LRU cap — add one if real-world use shows that dozens
/// of open max-size rendered documents make resident size matter.
///
/// Every entry is keyed by tab id AND pinned to the tab's standardized file
/// path: the inline Files browser replaces a tab's file in place (same id, new
/// URL), and serving the old file's render or scroll offset there would show
/// wrong content. Reads validate the path; `prune(keeping:)` drops entries
/// whose tab is gone or whose file changed.
///
/// Also holds each tab's collapsed branch-diff section keys — session-only,
/// never persisted, and pinned to the same path as everything else here.
struct DocumentTabMemory {
    struct Render {
        private enum Seed {
            case rendered(RenderedDocument)
            case rejected(DocumentURLValidator.Rejection)
            case readError(String)
        }

        private let seed: Seed
        let sectionIndex: BranchDiffSectionIndex?

        init(
            loadResult: DocumentLoader.LoadResult,
            renderedDoc: RenderedDocument?,
            sectionIndex: BranchDiffSectionIndex? = nil
        ) {
            switch loadResult {
            case .loaded:
                guard let renderedDoc else {
                    preconditionFailure("A successful document load must have a rendered document")
                }
                seed = .rendered(renderedDoc)
            case let .rejected(reason):
                seed = .rejected(reason)
            case let .readError(message):
                seed = .readError(message)
            }
            self.sectionIndex = sectionIndex
        }

        var loadResult: DocumentLoader.LoadResult {
            switch seed {
            case let .rendered(document):
                // The conflict-safe file snapshot is only meaningful during a
                // live load. The cached document bridges the remount until the
                // background load supplies one again.
                .loaded(source: document.source, snapshot: nil)
            case let .rejected(reason):
                .rejected(reason)
            case let .readError(message):
                .readError(message)
            }
        }

        var renderedDoc: RenderedDocument? {
            guard case let .rendered(document) = seed else { return nil }
            return document
        }
    }

    private struct Entry {
        let sourcePath: String
        var render: Render?
        var scrollAnchor: Int?
        var collapsedSections: Set<String> = []
        var isCopyMode = false
    }

    private var entries: [DocumentPane.ID: Entry] = [:]

    func render(for tab: DocumentPane) -> Render? {
        entry(for: tab)?.render
    }

    func scrollAnchor(for tab: DocumentPane) -> Int? {
        entry(for: tab)?.scrollAnchor
    }

    func collapsedSections(for tab: DocumentPane) -> Set<String> {
        // The struct is torn down or re-pointed on a workspace switch; the
        // registry is what makes twenty folded files still folded on return.
        entry(for: tab)?.collapsedSections
            ?? FoldRegistry.shared.keys(for: tab.id, path: tab.fileURL.standardizedFileURL.path)
    }

    func sectionIndex(for tab: DocumentPane) -> BranchDiffSectionIndex? {
        entry(for: tab)?.render?.sectionIndex
    }

    mutating func setCollapsedSections(_ keys: Set<String>, for tab: DocumentPane) {
        var entry = matchingOrFresh(for: tab)
        entry.collapsedSections = keys
        entries[tab.id] = entry
        FoldRegistry.shared.store(keys, for: tab.id, path: entry.sourcePath)
    }

    mutating func toggleSection(_ key: String, for tab: DocumentPane) {
        var keys = collapsedSections(for: tab)
        if keys.contains(key) { keys.remove(key) } else { keys.insert(key) }
        setCollapsedSections(keys, for: tab)
    }

    func isCopyMode(for tab: DocumentPane) -> Bool {
        entry(for: tab)?.isCopyMode ?? false
    }

    mutating func storeRender(_ render: Render, for tab: DocumentPane) {
        var entry = matchingOrFresh(for: tab)
        entry.render = render
        entries[tab.id] = entry
    }

    /// `nil` clears the anchor — a tab left scrolled to the top should reopen
    /// at the top, not at a stale offset.
    mutating func storeScrollAnchor(_ anchor: Int?, for tab: DocumentPane) {
        var entry = matchingOrFresh(for: tab)
        entry.scrollAnchor = anchor
        entries[tab.id] = entry
    }

    mutating func storeCopyMode(_ isCopyMode: Bool, for tab: DocumentPane) {
        var entry = matchingOrFresh(for: tab)
        entry.isCopyMode = isCopyMode
        entries[tab.id] = entry
    }

    /// Drops entries whose tab id is no longer present or whose tab now shows
    /// a different file (in-place replace).
    mutating func prune(keeping tabs: [DocumentPane]) {
        let paths = Dictionary(
            tabs.map { ($0.id, $0.fileURL.standardizedFileURL.path) },
            uniquingKeysWith: { first, _ in first }
        )
        entries = entries.filter { id, entry in paths[id] == entry.sourcePath }
    }

    private func entry(for tab: DocumentPane) -> Entry? {
        guard let entry = entries[tab.id],
              entry.sourcePath == tab.fileURL.standardizedFileURL.path
        else {
            return nil
        }
        return entry
    }

    private func matchingOrFresh(for tab: DocumentPane) -> Entry {
        if let entry = entry(for: tab) { return entry }
        let path = tab.fileURL.standardizedFileURL.path
        var fresh = Entry(sourcePath: path)
        fresh.collapsedSections = FoldRegistry.shared.keys(for: tab.id, path: path)
        return fresh
    }
}

/// Process-lifetime home for fold state, keyed by tab id and pinned to the
/// tab's path like every `DocumentTabMemory` entry. `DocumentTabMemory` is
/// `@State` on the group view, which SwiftUI tears down or re-points on a
/// workspace switch, and a user who folded twenty files expects them folded
/// when they come back. Renders and scroll anchors deliberately stay with the
/// view (they are large and cheap to rebuild); a set of keys is neither.
///
/// ponytail: never pruned. A closed tab's id never comes back, so the cost
/// of a stale entry is a few strings; prune from the tab-close path if a
/// long session ever makes that matter.
final class FoldRegistry: @unchecked Sendable {
    static let shared = FoldRegistry()

    private let lock = NSLock()
    private var folds: [DocumentPane.ID: (path: String, keys: Set<String>)] = [:]

    func keys(for id: DocumentPane.ID, path: String) -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = folds[id], entry.path == path else { return [] }
        return entry.keys
    }

    func store(_ keys: Set<String>, for id: DocumentPane.ID, path: String) {
        lock.lock()
        defer { lock.unlock() }
        folds[id] = (path, keys)
    }
}
