import AwesoMuxCore
import Foundation
import Testing
@testable import awesoMux

@MainActor
@Suite("Local diagnostic events")
struct LocalDiagnosticEventRecorderTests {
    @Test("retains bounded structured events and filters issues independently")
    func retentionAndFiltering() {
        let recorder = LocalDiagnosticEventRecorder(retention: 60, maximumEntries: 3)
        recorder.record(.terminalReady, at: Date(timeIntervalSince1970: 0))
        recorder.record(.configurationReloaded(trigger: .manual), at: Date(timeIntervalSince1970: 10))
        recorder.record(.runtimeEventRejected, at: Date(timeIntervalSince1970: 20))
        recorder.record(.runtimeEventsDropped, at: Date(timeIntervalSince1970: 30))

        let snapshot = recorder.snapshot(now: Date(timeIntervalSince1970: 30))
        #expect(snapshot.events.count == 3)
        #expect(snapshot.events.map(\.category) == [.configuration, .runtime, .runtime])
        #expect(snapshot.issueCount == 2)
        #expect(snapshot.malformedOrDroppedCount == 2)
        #expect(snapshot.filtered(scope: .issues, category: .runtime).count == 2)
        #expect(snapshot.filtered(scope: .all, category: .configuration).count == 1)
    }

    @Test("prunes expired events before applying severity and category filters")
    func timePruningAndFilterCrossProduct() {
        let recorder = LocalDiagnosticEventRecorder(retention: 30, maximumEntries: 10)
        recorder.record(.configurationRejected(trigger: .watcher), at: Date(timeIntervalSince1970: 0))
        recorder.record(.configurationReloaded(trigger: .watcher), at: Date(timeIntervalSince1970: 20))
        recorder.record(.runtimeEventRejected, at: Date(timeIntervalSince1970: 40))

        let snapshot = recorder.snapshot(now: Date(timeIntervalSince1970: 40))

        #expect(snapshot.events.count == 2)
        #expect(snapshot.filtered(scope: .issues, category: .configuration).isEmpty)
        #expect(snapshot.filtered(scope: .issues, category: .runtime).count == 1)
    }

    @Test("high-volume issue retention keeps only the newest bounded events")
    func highVolumeRetentionKeepsNewestEvents() {
        let recorder = LocalDiagnosticEventRecorder(retention: 10_000, maximumEntries: 3)
        for second in 0 ..< 300 {
            recorder.record(.runtimeEventRejected, at: Date(timeIntervalSince1970: Double(second)))
        }

        let snapshot = recorder.snapshot(now: Date(timeIntervalSince1970: 299))

        #expect(snapshot.events.map(\.timestamp) == [297, 298, 299].map(Date.init(timeIntervalSince1970:)))
        #expect(snapshot.warningCount == 3)
    }

    @Test("visible event helper returns newest-first capped rows")
    func visibleEventsNewestFirstCap() {
        let recorder = LocalDiagnosticEventRecorder(retention: 10_000, maximumEntries: 50)
        for second in 0 ..< 10 {
            recorder.record(.terminalReady, at: Date(timeIntervalSince1970: Double(second)))
        }
        let events = recorder.snapshot(now: Date(timeIntervalSince1970: 10)).events
        let visible = LocalDiagnosticEventSnapshot.visibleEvents(events, limit: 3)

        #expect(visible.map(\.timestamp) == [9, 8, 7].map(Date.init(timeIntervalSince1970:)))
    }
}
