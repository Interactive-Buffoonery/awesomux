import Foundation
import Testing
@testable import awesoMux

@Suite("Diagnostics history")
struct DiagnosticsHistoryTests {
    @Test("empty windows report a gap instead of a zero-valued sample")
    func emptyWindowIsAGap() {
        let history = DiagnosticsHistory()

        let summary = history.summary(metric: .cpu, window: 300, now: Date())

        #expect(summary.sampleCount == 0)
    }

    @Test("keeps one hour and computes selected-window summaries")
    func retentionAndSummary() {
        var history = DiagnosticsHistory(retention: 60, maximumSamples: 20)
        for second in stride(from: 0, through: 90, by: 10) {
            history.append(sample(cpu: Double(second), memory: Int64(second * 1_000), at: Double(second)))
        }

        #expect(history.samples.count == 7)
        #expect(history.samples.first?.timestamp == Date(timeIntervalSince1970: 30))
        let summary = history.summary(metric: .cpu, window: 30, now: Date(timeIntervalSince1970: 90))
        #expect(summary.sampleCount == 4)
        #expect(summary.current == 90)
        #expect(summary.average == 75)
        #expect(summary.peak == 90)
        #expect(summary.trend == .rising)
    }

    @Test("default retention holds one hour of thirty-second samples")
    func defaultSampleLimit() {
        var history = DiagnosticsHistory(retention: 10_000)
        for second in stride(from: 0, through: 3_600, by: 30) {
            history.append(sample(cpu: Double(second), memory: Int64(second), at: Double(second)))
        }

        #expect(history.samples.count == 120)
        #expect(history.samples.first?.timestamp == Date(timeIntervalSince1970: 30))
    }

    @Test("failed intervals are gaps rather than zero-valued samples")
    func failuresAreGaps() {
        var history = DiagnosticsHistory(retention: 60, maximumSamples: 20)
        history.append(sample(cpu: 20, memory: 2_000, at: 0))
        history.append(sample(cpu: 40, memory: 4_000, at: 10))

        let summary = history.summary(metric: .cpu, window: 30, now: Date(timeIntervalSince1970: 20))
        #expect(summary.sampleCount == 2)
        #expect(summary.average == 30)
    }

    private func sample(cpu: Double, memory: Int64, at timestamp: TimeInterval) -> DiagnosticsHistorySample {
        DiagnosticsHistorySample(
            timestamp: Date(timeIntervalSince1970: timestamp),
            cpuPercent: cpu,
            residentBytes: memory
        )
    }
}
