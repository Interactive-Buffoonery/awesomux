import Foundation

struct DiagnosticsHistory: Equatable, Sendable {
    private(set) var samples: [DiagnosticsHistorySample] = []
    private let retention: TimeInterval
    private let maximumSamples: Int

    init(
        retention: TimeInterval = 3_600,
        maximumSamples: Int = 120
    ) {
        self.retention = retention
        self.maximumSamples = maximumSamples
    }

    mutating func append(_ sample: DiagnosticsHistorySample) {
        samples.append(sample)
        let cutoff = sample.timestamp.addingTimeInterval(-retention)
        samples.removeAll { $0.timestamp < cutoff }
        if samples.count > maximumSamples {
            samples.removeFirst(samples.count - maximumSamples)
        }
    }

    mutating func append(_ snapshot: DiagnosticsProcessSnapshot) {
        append(DiagnosticsHistorySample(
            timestamp: snapshot.collectedAt,
            cpuPercent: snapshot.aggregateCPUPercent,
            residentBytes: snapshot.aggregateResidentBytes
        ))
    }

    func projection(
        metric: DiagnosticsMetric,
        window: TimeInterval,
        now: Date
    ) -> DiagnosticsHistoryProjection {
        let visible = values(window: window, now: now)
        return DiagnosticsHistoryProjection(
            samples: visible,
            summary: Self.summary(for: visible, metric: metric)
        )
    }

    func values(window: TimeInterval, now: Date) -> [DiagnosticsHistorySample] {
        let cutoff = now.addingTimeInterval(-window)
        return samples.filter { $0.timestamp >= cutoff && $0.timestamp <= now }
    }

    func summary(metric: DiagnosticsMetric, window: TimeInterval, now: Date) -> DiagnosticsHistorySummary {
        projection(metric: metric, window: window, now: now).summary
    }

    private static func summary(
        for samples: [DiagnosticsHistorySample],
        metric: DiagnosticsMetric
    ) -> DiagnosticsHistorySummary {
        let metrics = samples.map { sample -> Double in
            switch metric {
            case .cpu: sample.cpuPercent
            case .memory: Double(sample.residentBytes)
            }
        }
        guard let current = metrics.last, let peak = metrics.max() else { return .empty }
        let average = metrics.reduce(0, +) / Double(metrics.count)
        let trend: DiagnosticsTrend
        if let first = metrics.first, current > first * 1.05 + 0.5 {
            trend = .rising
        } else if let first = metrics.first, current < first * 0.95 - 0.5 {
            trend = .falling
        } else {
            trend = .steady
        }
        return DiagnosticsHistorySummary(
            current: current,
            average: average,
            peak: peak,
            sampleCount: metrics.count,
            trend: trend
        )
    }
}
