import AwesoMuxCore
import Foundation

/// Session-memory for the document tab strip (INT-748 PR2): the last rendered
/// document and scroll anchor per open tab, held as `@State` by
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
struct DocumentTabMemory {
    struct Render {
        private enum Seed {
            case rendered(RenderedDocument)
            case rejected(DocumentURLValidator.Rejection)
            case readError(String)
        }

        private let seed: Seed

        init(
            loadResult: DocumentLoader.LoadResult,
            renderedDoc: RenderedDocument?
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
        }

        var loadResult: DocumentLoader.LoadResult {
            switch seed {
            case let .rendered(document):
                // The parsed tree and conflict-safe file snapshot are only
                // needed during a live load. The cached document bridges the
                // remount until that background load supplies both again.
                .loaded([], source: document.source, snapshot: nil)
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
    }

    private var entries: [DocumentPane.ID: Entry] = [:]

    func render(for tab: DocumentPane) -> Render? {
        entry(for: tab)?.render
    }

    func scrollAnchor(for tab: DocumentPane) -> Int? {
        entry(for: tab)?.scrollAnchor
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
        entry(for: tab) ?? Entry(sourcePath: tab.fileURL.standardizedFileURL.path)
    }
}
