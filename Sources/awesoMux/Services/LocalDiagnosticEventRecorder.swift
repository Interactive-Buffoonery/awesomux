import Foundation

@MainActor
final class LocalDiagnosticEventRecorder {
    private var events: [LocalDiagnosticEvent] = []
    private var firstRetainedIndex = 0
    private let retention: TimeInterval
    private let maximumEntries: Int
    private var inputObserver: ((LocalDiagnosticEventInput) -> Void)?

    init(retention: TimeInterval = 3_600, maximumEntries: Int = 500) {
        self.retention = retention
        self.maximumEntries = maximumEntries
    }

    /// Installs the one app-lifetime observer after runtime composition has
    /// created all consumers. Earlier startup inputs remain local-only.
    func setInputObserver(_ observer: @escaping (LocalDiagnosticEventInput) -> Void) {
        precondition(inputObserver == nil, "diagnostic input observer may only be installed once")
        inputObserver = observer
    }

    func record(_ input: LocalDiagnosticEventInput, at timestamp: Date = Date()) {
        let presentation = Self.presentation(for: input)
        events.append(LocalDiagnosticEvent(
            id: UUID(),
            timestamp: timestamp,
            severity: presentation.severity,
            category: presentation.category,
            summary: presentation.summary,
            isMalformedOrDropped: presentation.isMalformedOrDropped
        ))
        prune(now: timestamp)
        inputObserver?(input)
    }

    func snapshot(now: Date = Date()) -> LocalDiagnosticEventSnapshot {
        prune(now: now)
        return LocalDiagnosticEventSnapshot(events: Array(events[firstRetainedIndex...]))
    }

    func removeExpiredEvents(at date: Date = Date()) {
        prune(now: date)
    }

    private func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-retention)
        while firstRetainedIndex < events.count,
              events[firstRetainedIndex].timestamp < cutoff {
            firstRetainedIndex += 1
        }
        let retainedCount = events.count - firstRetainedIndex
        if retainedCount > maximumEntries {
            firstRetainedIndex += retainedCount - maximumEntries
        }
        if firstRetainedIndex >= 256,
           firstRetainedIndex * 2 >= events.count {
            events.removeFirst(firstRetainedIndex)
            firstRetainedIndex = 0
        }
    }

    private static func presentation(
        for input: LocalDiagnosticEventInput
    ) -> (severity: LocalDiagnosticSeverity, category: LocalDiagnosticCategory, summary: String, isMalformedOrDropped: Bool) {
        switch input {
        case .runtimeEventRejected:
            return (.warning, .runtime, String(localized: "Malformed runtime event was ignored", comment: "Diagnostics event summary"), true)
        case .runtimeEventsDropped:
            return (.warning, .runtime, String(localized: "Oversized runtime event data was dropped", comment: "Diagnostics event summary"), true)
        case .runtimeEventFileUnavailable:
            return (.error, .runtime, String(localized: "Runtime event file could not be read safely", comment: "Diagnostics event summary"), false)
        case let .configurationReloaded(trigger):
            let summary: String = switch trigger {
            case .manual:
                String(localized: "Manual configuration reload succeeded", comment: "Diagnostics event summary")
            case .watcher:
                String(localized: "File watcher configuration reload succeeded", comment: "Diagnostics event summary")
            }
            return (.info, .configuration, summary, false)
        case let .configurationRejected(trigger):
            let summary: String = switch trigger {
            case .manual:
                String(localized: "Manual configuration reload was rejected", comment: "Diagnostics event summary")
            case .watcher:
                String(localized: "File watcher configuration reload was rejected", comment: "Diagnostics event summary")
            }
            return (.error, .configuration, summary, false)
        case .configurationReset:
            return (.warning, .configuration, String(localized: "Configuration was reset after the file was removed", comment: "Diagnostics event summary"), false)
        case .configurationResetRejected:
            return (.error, .configuration, String(localized: "Configuration could not be reset after the file was removed", comment: "Diagnostics event summary"), false)
        case .restoreArchived:
            return (.error, .restore, String(localized: "Saved workspaces could not be decoded; the original snapshot was archived", comment: "Diagnostics event summary"), false)
        case .restoreSanitized:
            return (.warning, .restore, String(localized: "Unsafe saved workspace fields were sanitized during restore", comment: "Diagnostics event summary"), false)
        case .terminalReady:
            return (.info, .terminal, String(localized: "Terminal runtime initialized", comment: "Diagnostics event summary"), false)
        case .terminalReloaded:
            return (.info, .terminal, String(localized: "Terminal runtime reloaded", comment: "Diagnostics event summary"), false)
        case .terminalFailed:
            return (.error, .terminal, String(localized: "Terminal runtime failed to initialize", comment: "Diagnostics event summary"), false)
        case .processSamplingFailed:
            return (.warning, .runtime, String(localized: "Process resource sample was unavailable", comment: "Diagnostics event summary"), false)
        }
    }

}
