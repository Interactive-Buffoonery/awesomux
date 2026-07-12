import Foundation

enum LocalDiagnosticSeverity: String, Sendable {
    case info = "Info"
    case warning = "Warning"
    case error = "Error"

    var displayName: String {
        switch self {
        case .info: String(localized: "Info", comment: "Diagnostics event severity")
        case .warning: String(localized: "Warning", comment: "Diagnostics event severity")
        case .error: String(localized: "Error", comment: "Diagnostics event severity")
        }
    }
}

enum LocalDiagnosticCategory: String, CaseIterable, Sendable {
    case runtime = "Runtime"
    case restore = "Restore"
    case configuration = "Configuration"
    case terminal = "Terminal"

    var displayName: String {
        switch self {
        case .runtime: String(localized: "Runtime", comment: "Diagnostics event category")
        case .restore: String(localized: "Restore", comment: "Diagnostics event category")
        case .configuration: String(localized: "Configuration", comment: "Diagnostics event category")
        case .terminal: String(localized: "Terminal", comment: "Diagnostics event category")
        }
    }
}

enum LocalDiagnosticIssueScope: String, CaseIterable, Sendable {
    case all = "All events"
    case issues = "Issues"

    var displayName: String {
        switch self {
        case .all: String(localized: "All events", comment: "Diagnostics severity filter")
        case .issues: String(localized: "Issues", comment: "Diagnostics severity filter")
        }
    }
}

enum LocalDiagnosticConfigurationTrigger: String, Sendable {
    case manual = "Manual"
    case watcher = "File watcher"

    var displayName: String {
        switch self {
        case .manual: String(localized: "Manual", comment: "Diagnostics configuration reload trigger")
        case .watcher: String(localized: "File watcher", comment: "Diagnostics configuration reload trigger")
        }
    }
}

enum LocalDiagnosticEventInput: Equatable, Sendable {
    case runtimeEventRejected
    case runtimeEventsDropped
    case runtimeEventFileUnavailable
    case configurationReloaded(trigger: LocalDiagnosticConfigurationTrigger)
    case configurationRejected(trigger: LocalDiagnosticConfigurationTrigger)
    case configurationReset
    case configurationResetRejected
    case restoreArchived
    case restoreSanitized
    case terminalReady
    case terminalReloaded
    case terminalFailed
    case processSamplingFailed
}

struct LocalDiagnosticEvent: Identifiable, Equatable, Sendable {
    let id: UUID
    let timestamp: Date
    let severity: LocalDiagnosticSeverity
    let category: LocalDiagnosticCategory
    let summary: String
    let isMalformedOrDropped: Bool
}

struct LocalDiagnosticEventSnapshot: Equatable, Sendable {
    let events: [LocalDiagnosticEvent]
    let errorCount: Int
    let warningCount: Int
    let malformedOrDroppedCount: Int

    var issueCount: Int { errorCount + warningCount }

    init(events: [LocalDiagnosticEvent]) {
        self.events = events
        var errorCount = 0
        var warningCount = 0
        var malformedOrDroppedCount = 0
        for event in events {
            if event.severity == .error { errorCount += 1 }
            if event.severity == .warning { warningCount += 1 }
            if event.isMalformedOrDropped { malformedOrDroppedCount += 1 }
        }
        self.errorCount = errorCount
        self.warningCount = warningCount
        self.malformedOrDroppedCount = malformedOrDroppedCount
    }

    func filtered(
        scope: LocalDiagnosticIssueScope,
        category: LocalDiagnosticCategory?
    ) -> [LocalDiagnosticEvent] {
        events.filter { event in
            let matchesScope = scope == .all || event.severity != .info
            let matchesCategory = category == nil || event.category == category
            return matchesScope && matchesCategory
        }
    }

    /// Maximum rows rendered in the Diagnostics events list. The recorder may
    /// retain more for counts and filters; the UI shows only the newest N.
    static let maxVisibleEvents = 100

    /// Newest-first prefix for the UI list (does not mutate the recorder).
    static func visibleEvents(
        _ events: [LocalDiagnosticEvent],
        limit: Int = maxVisibleEvents
    ) -> [LocalDiagnosticEvent] {
        guard limit > 0 else { return [] }
        return Array(events.reversed().prefix(limit))
    }
}
