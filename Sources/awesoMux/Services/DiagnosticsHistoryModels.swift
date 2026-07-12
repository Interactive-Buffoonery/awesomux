import Foundation

enum DiagnosticsMetric: String, CaseIterable, Sendable {
    case cpu
    case memory

    var displayName: String {
        switch self {
        case .cpu: String(localized: "CPU", comment: "Diagnostics resource metric")
        case .memory: String(localized: "Memory", comment: "Diagnostics resource metric")
        }
    }
}

enum DiagnosticsTrend: String, Sendable {
    case rising
    case falling
    case steady

    var displayName: String {
        switch self {
        case .rising: String(localized: "Rising", comment: "Diagnostics resource trend")
        case .falling: String(localized: "Falling", comment: "Diagnostics resource trend")
        case .steady: String(localized: "Steady", comment: "Diagnostics resource trend")
        }
    }
}

struct DiagnosticsHistorySample: Identifiable, Equatable, Sendable {
    var id: Date { timestamp }
    let timestamp: Date
    let cpuPercent: Double
    let residentBytes: Int64
}

struct DiagnosticsHistorySummary: Equatable, Sendable {
    let current: Double
    let average: Double
    let peak: Double
    let sampleCount: Int
    let trend: DiagnosticsTrend

    static let empty = DiagnosticsHistorySummary(
        current: 0,
        average: 0,
        peak: 0,
        sampleCount: 0,
        trend: .steady
    )
}

struct DiagnosticsHistoryProjection: Equatable, Sendable {
    let samples: [DiagnosticsHistorySample]
    let summary: DiagnosticsHistorySummary
}
