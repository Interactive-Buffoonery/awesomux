import AwesoMuxCore

struct DocumentRevisionIndicatorState: Equatable {
    enum Presentation: Equatable {
        case expanded
        case compact
    }

    struct Indicator: Equatable {
        let revision: LineDiffCount
        let generation: Int
        var presentation: Presentation
        var activeViewingTime: Duration
    }

    private struct Entry: Equatable {
        let sourcePath: String
        var indicator: Indicator
    }

    private var entries: [DocumentPane.ID: Entry] = [:]
    private var nextGeneration = 0

    func indicator(for tab: DocumentPane) -> Indicator? {
        guard let entry = entries[tab.id],
              entry.sourcePath == tab.fileURL.standardizedFileURL.path
        else {
            return nil
        }
        return entry.indicator
    }

    mutating func record(_ revision: LineDiffCount, for tab: DocumentPane) {
        nextGeneration += 1
        entries[tab.id] = Entry(
            sourcePath: tab.fileURL.standardizedFileURL.path,
            indicator: Indicator(
                revision: revision,
                generation: nextGeneration,
                presentation: .expanded,
                activeViewingTime: .zero
            )
        )
    }

    mutating func recordActiveViewingTime(
        _ duration: Duration,
        for tab: DocumentPane,
        generation: Int
    ) {
        guard duration > .zero,
              var entry = entries[tab.id],
              entry.sourcePath == tab.fileURL.standardizedFileURL.path,
              entry.indicator.generation == generation,
              entry.indicator.presentation == .expanded
        else {
            return
        }
        entry.indicator.activeViewingTime += duration
        entries[tab.id] = entry
    }

    func remainingExpandedTime(of total: Duration, for tab: DocumentPane) -> Duration? {
        guard let indicator = indicator(for: tab) else { return nil }
        let remaining = total - indicator.activeViewingTime
        return remaining > .zero ? remaining : .zero
    }

    mutating func collapse(for tab: DocumentPane) {
        updatePresentation(.compact, for: tab)
    }

    mutating func expand(for tab: DocumentPane) {
        guard var entry = entries[tab.id],
              entry.sourcePath == tab.fileURL.standardizedFileURL.path
        else {
            return
        }
        entry.indicator.presentation = .expanded
        entry.indicator.activeViewingTime = .zero
        entries[tab.id] = entry
    }

    mutating func dismiss(for tab: DocumentPane) {
        guard indicator(for: tab) != nil else { return }
        entries[tab.id] = nil
    }

    mutating func prune(keeping tabs: [DocumentPane]) {
        let paths = Dictionary(
            tabs.map { ($0.id, $0.fileURL.standardizedFileURL.path) },
            uniquingKeysWith: { first, _ in first }
        )
        entries = entries.filter { id, entry in paths[id] == entry.sourcePath }
    }

    private mutating func updatePresentation(_ presentation: Presentation, for tab: DocumentPane) {
        guard var entry = entries[tab.id],
              entry.sourcePath == tab.fileURL.standardizedFileURL.path
        else {
            return
        }
        entry.indicator.presentation = presentation
        entries[tab.id] = entry
    }
}
