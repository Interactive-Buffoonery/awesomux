import AwesoMuxCore
import AwesoMuxTestSupport
import Foundation
import Testing

@testable import awesoMux

// MARK: - DocumentRevisionMonitorTests

/// Exercises `DocumentRevisionMonitor` (INT-782): background-tab revision
/// detection over real files and watchers, baseline semantics, self-write
/// suppression, reconcile-on-select, pruning, and announcement dedup.
///
/// The suite is @MainActor to match the monitor's isolation and the other
/// watcher-driven suites. All polls are bounded; negative checks use short
/// fixed waits (the event pipeline settles well inside them: 100 ms debounce
/// plus one read and one diff).
@MainActor
@Suite("DocumentRevisionMonitor")
struct DocumentRevisionMonitorTests {

    private final class AnnouncementLog {
        var messages: [String] = []
    }

    /// Three lines; edits below append so exact +N counts are predictable.
    private static let baseContent = "line1\nline2\nline3"

    private func makeMonitor(log: AnnouncementLog) -> DocumentRevisionMonitor {
        let monitor = DocumentRevisionMonitor()
        monitor.announce = { log.messages.append($0) }
        monitor.selfWriteContext = { _, _ in nil }
        return monitor
    }

    private func awaitCondition(
        timeout seconds: Double,
        condition: () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    /// Two-file fixture: tab A (selected) and tab B (background), both with
    /// baselines seeded through `cachedSource` as if the user had viewed them.
    private struct Fixture {
        let directory: TemporaryDirectory
        let tabA: DocumentPane
        let tabB: DocumentPane

        var urlB: URL { tabB.fileURL }
    }

    private func withFixture(
        body: @MainActor (Fixture, DocumentRevisionMonitor, AnnouncementLog) async throws -> Void
    ) async throws {
        let directory = try TemporaryDirectory(prefix: "DocumentRevisionMonitorTests")
        defer { withExtendedLifetime(directory) {} }

        let urlA = directory.url.appendingPathComponent("a.md")
        let urlB = directory.url.appendingPathComponent("b.md")
        try Self.baseContent.write(to: urlA, atomically: false, encoding: .utf8)
        try Self.baseContent.write(to: urlB, atomically: false, encoding: .utf8)

        let fixture = Fixture(
            directory: directory,
            tabA: DocumentPane(fileURL: urlA, title: "a.md"),
            tabB: DocumentPane(fileURL: urlB, title: "b.md")
        )
        let log = AnnouncementLog()
        let monitor = makeMonitor(log: log)
        monitor.sync(
            tabs: [fixture.tabA, fixture.tabB],
            selectedTabID: fixture.tabA.id,
            cachedSource: { _ in Self.baseContent }
        )
        // Give the vnode sources a tick to arm before the first edit.
        try await Task.sleep(nanoseconds: 50_000_000)

        try await body(fixture, monitor, log)
        monitor.stopAll()
    }

    private func exactDiff(
        _ indicator: DocumentRevisionIndicatorState.Indicator?
    ) -> LineDiffCount? {
        guard case let .exact(diff) = indicator?.revision else { return nil }
        return diff
    }

    // MARK: - Background detection

    @Test("background edit records an exact diff and announces once")
    func backgroundEditRecordsIndicator() async throws {
        try await withFixture { fixture, monitor, log in
            let edited = Self.baseContent + "\nline4\nline5"
            try edited.write(to: fixture.urlB, atomically: true, encoding: .utf8)

            let recorded = await awaitCondition(timeout: 3.0) {
                self.exactDiff(monitor.indicator(for: fixture.tabB)) != nil
            }
            #expect(recorded)
            #expect(exactDiff(monitor.indicator(for: fixture.tabB)) == LineDiffCount(added: 2, removed: 0))
            #expect(log.messages.count == 1)
            #expect(log.messages.first?.contains("b.md") == true)
        }
    }

    @Test("identical re-write does not re-record or re-announce")
    func identicalContentDeduplicates() async throws {
        try await withFixture { fixture, monitor, log in
            let edited = Self.baseContent + "\nline4"
            try edited.write(to: fixture.urlB, atomically: true, encoding: .utf8)
            let recorded = await awaitCondition(timeout: 3.0) {
                monitor.indicator(for: fixture.tabB) != nil
            }
            #expect(recorded)
            let generation = monitor.indicator(for: fixture.tabB)?.generation

            // Same bytes again: the watcher fires but lastSeenOnDisk matches.
            try edited.write(to: fixture.urlB, atomically: true, encoding: .utf8)
            try await Task.sleep(nanoseconds: 700_000_000)

            #expect(monitor.indicator(for: fixture.tabB)?.generation == generation)
            #expect(log.messages.count == 1)
        }
    }

    @Test("successive background edits diff from the baseline, not edit-to-edit")
    func successiveEditsAccumulate() async throws {
        try await withFixture { fixture, monitor, log in
            try (Self.baseContent + "\nline4\nline5").write(
                to: fixture.urlB, atomically: true, encoding: .utf8)
            _ = await awaitCondition(timeout: 3.0) {
                monitor.indicator(for: fixture.tabB) != nil
            }

            try (Self.baseContent + "\nline4\nline5\nline6").write(
                to: fixture.urlB, atomically: true, encoding: .utf8)
            let accumulated = await awaitCondition(timeout: 3.0) {
                self.exactDiff(monitor.indicator(for: fixture.tabB))?.added == 3
            }
            #expect(accumulated, "second edit should count from the last version the user saw")
            #expect(exactDiff(monitor.indicator(for: fixture.tabB))?.removed == 0)
        }
    }

    @Test("first observation seeds the baseline and never indicates")
    func firstObservationNeverIndicates() async throws {
        let directory = try TemporaryDirectory(prefix: "DocumentRevisionMonitorTests")
        defer { withExtendedLifetime(directory) {} }
        let url = directory.url.appendingPathComponent("fresh.md")
        try Self.baseContent.write(to: url, atomically: false, encoding: .utf8)
        let tab = DocumentPane(fileURL: url, title: "fresh.md")
        let selected = DocumentPane(
            fileURL: directory.url.appendingPathComponent("other.md"), title: "other.md")

        let log = AnnouncementLog()
        let monitor = makeMonitor(log: log)
        // No cached render: the monitor's async seed read becomes the baseline.
        monitor.sync(tabs: [selected, tab], selectedTabID: selected.id, cachedSource: { _ in nil })
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(monitor.indicator(for: tab) == nil)

        try (Self.baseContent + "\nline4").write(to: url, atomically: true, encoding: .utf8)
        let recorded = await awaitCondition(timeout: 3.0) {
            self.exactDiff(monitor.indicator(for: tab)) == LineDiffCount(added: 1, removed: 0)
        }
        #expect(recorded, "an edit after the seeded first observation should indicate")
        monitor.stopAll()
    }

    // MARK: - Suppression rules

    @Test("self-write is suppressed and advances the baseline")
    func selfWriteSuppressedAndAdvancesBaseline() async throws {
        try await withFixture { fixture, monitor, log in
            let selfWritten = Self.baseContent + "\nannotation"
            monitor.selfWriteContext = { _, onDisk in
                onDisk == selfWritten
                    ? MarkdownSelfWriteContext(source: selfWritten, isSelfWrite: true)
                    : nil
            }
            try selfWritten.write(to: fixture.urlB, atomically: true, encoding: .utf8)
            try await Task.sleep(nanoseconds: 700_000_000)
            #expect(monitor.indicator(for: fixture.tabB) == nil)
            #expect(log.messages.isEmpty)

            // A later external edit counts from the self-written source, not
            // the pre-self-write baseline (+1, not +2).
            try (selfWritten + "\nexternal").write(to: fixture.urlB, atomically: true, encoding: .utf8)
            let recorded = await awaitCondition(timeout: 3.0) {
                self.exactDiff(monitor.indicator(for: fixture.tabB)) == LineDiffCount(added: 1, removed: 0)
            }
            #expect(recorded)
        }
    }

    @Test("manual dismiss resets announcement dedup after a self-write")
    func manualDismissResetsAnnouncementDedup() async throws {
        try await withFixture { fixture, monitor, log in
            let edited = Self.baseContent + "\nexternal"
            try edited.write(to: fixture.urlB, atomically: true, encoding: .utf8)
            let firstRecorded = await awaitCondition(timeout: 3.0) {
                monitor.indicator(for: fixture.tabB) != nil
            }
            #expect(firstRecorded)
            #expect(log.messages.count == 1)

            monitor.dismiss(for: fixture.tabB)
            #expect(monitor.indicator(for: fixture.tabB) == nil)

            let selfWritten = Self.baseContent + "\nannotation"
            monitor.selfWriteContext = { _, onDisk in
                onDisk == selfWritten
                    ? MarkdownSelfWriteContext(source: selfWritten, isSelfWrite: true)
                    : nil
            }
            try selfWritten.write(to: fixture.urlB, atomically: true, encoding: .utf8)
            try await Task.sleep(nanoseconds: 700_000_000)
            #expect(monitor.indicator(for: fixture.tabB) == nil)
            #expect(log.messages.count == 1)

            try edited.write(to: fixture.urlB, atomically: true, encoding: .utf8)
            let reRecorded = await awaitCondition(timeout: 3.0) {
                monitor.indicator(for: fixture.tabB) != nil && log.messages.count == 2
            }
            #expect(reRecorded)
        }
    }

    @Test("coalesced self-write and external edit diff from the user's own source")
    func coalescedSelfWriteUsesRegistrySource() async throws {
        try await withFixture { fixture, monitor, _ in
            let selfWritten = Self.baseContent + "\nannotation"
            monitor.selfWriteContext = { _, _ in
                MarkdownSelfWriteContext(source: selfWritten, isSelfWrite: false)
            }
            // Disk gained the annotation plus two external lines; the diff
            // must be measured from the annotation (+2), not the baseline (+3).
            try (selfWritten + "\nx\ny").write(to: fixture.urlB, atomically: true, encoding: .utf8)
            let recorded = await awaitCondition(timeout: 3.0) {
                self.exactDiff(monitor.indicator(for: fixture.tabB)) == LineDiffCount(added: 2, removed: 0)
            }
            #expect(recorded)
        }
    }

    @Test("deleting the file never indicates")
    func deletedFileDoesNotIndicate() async throws {
        try await withFixture { fixture, monitor, log in
            try FileManager.default.removeItem(at: fixture.urlB)
            try await Task.sleep(nanoseconds: 700_000_000)
            #expect(monitor.indicator(for: fixture.tabB) == nil)
            #expect(log.messages.isEmpty)
        }
    }

    @Test("recreation with changes after a delete indicates against the old baseline")
    func recreationAfterDeleteIndicates() async throws {
        try await withFixture { fixture, monitor, _ in
            try FileManager.default.removeItem(at: fixture.urlB)
            // Recreate inside the watcher's re-arm retry budget (~200 ms).
            try await Task.sleep(nanoseconds: 30_000_000)
            try (Self.baseContent + "\nline4").write(
                to: fixture.urlB, atomically: false, encoding: .utf8)

            let recorded = await awaitCondition(timeout: 3.0) {
                self.exactDiff(monitor.indicator(for: fixture.tabB)) == LineDiffCount(added: 1, removed: 0)
            }
            #expect(recorded)
        }
    }

    @Test("content returning exactly to the baseline dismisses the indicator")
    func returnToBaselineDismisses() async throws {
        try await withFixture { fixture, monitor, _ in
            try (Self.baseContent + "\nline4").write(to: fixture.urlB, atomically: true, encoding: .utf8)
            let recorded = await awaitCondition(timeout: 3.0) {
                monitor.indicator(for: fixture.tabB) != nil
            }
            #expect(recorded)

            try Self.baseContent.write(to: fixture.urlB, atomically: true, encoding: .utf8)
            let dismissed = await awaitCondition(timeout: 3.0) {
                monitor.indicator(for: fixture.tabB) == nil
            }
            #expect(dismissed, "a stale marker would claim changes that no longer exist")
        }
    }

    // MARK: - Selection semantics

    @Test("watcher events for the selected tab are left to the pane pipeline")
    func selectedTabIsSkipped() async throws {
        try await withFixture { fixture, monitor, log in
            try (Self.baseContent + "\nline4").write(
                to: fixture.tabA.fileURL, atomically: true, encoding: .utf8)
            try await Task.sleep(nanoseconds: 700_000_000)
            #expect(monitor.indicator(for: fixture.tabA) == nil)
            #expect(log.messages.isEmpty)
        }
    }

    @Test("reconcile records an edit the watcher missed during a selection change")
    func reconcileRecordsMissedEdit() async throws {
        try await withFixture { fixture, monitor, log in
            // Simulate the debounce-window gap: no watcher is live when the
            // edit lands, so only the reconcile read can see it.
            monitor.stopAll()
            try (Self.baseContent + "\nline4\nline5").write(
                to: fixture.urlB, atomically: true, encoding: .utf8)

            monitor.sync(
                tabs: [fixture.tabA, fixture.tabB],
                selectedTabID: fixture.tabB.id,
                cachedSource: { _ in Self.baseContent }
            )
            monitor.reconcile(tab: fixture.tabB)

            let recorded = await awaitCondition(timeout: 3.0) {
                self.exactDiff(monitor.indicator(for: fixture.tabB)) == LineDiffCount(added: 2, removed: 0)
            }
            #expect(recorded)
            #expect(log.messages.count == 1)
        }
    }

    // MARK: - Isolation and pruning

    @Test("two background tabs on one file both record but announce once")
    func sameFileTwoTabsAnnounceOnce() async throws {
        let directory = try TemporaryDirectory(prefix: "DocumentRevisionMonitorTests")
        defer { withExtendedLifetime(directory) {} }
        let urlA = directory.url.appendingPathComponent("a.md")
        let shared = directory.url.appendingPathComponent("shared.md")
        try Self.baseContent.write(to: urlA, atomically: false, encoding: .utf8)
        try Self.baseContent.write(to: shared, atomically: false, encoding: .utf8)

        let tabA = DocumentPane(fileURL: urlA, title: "a.md")
        let tabB = DocumentPane(fileURL: shared, title: "shared.md")
        let tabC = DocumentPane(fileURL: shared, title: "shared.md")

        let log = AnnouncementLog()
        let monitor = makeMonitor(log: log)
        monitor.sync(
            tabs: [tabA, tabB, tabC],
            selectedTabID: tabA.id,
            cachedSource: { _ in Self.baseContent }
        )
        try await Task.sleep(nanoseconds: 50_000_000)

        try (Self.baseContent + "\nline4").write(to: shared, atomically: true, encoding: .utf8)
        let bothRecorded = await awaitCondition(timeout: 3.0) {
            monitor.indicator(for: tabB) != nil && monitor.indicator(for: tabC) != nil
        }
        #expect(bothRecorded)
        #expect(log.messages.count == 1)
        monitor.stopAll()
    }

    @Test("in-place file replacement prunes state and resets the baseline")
    func inPlaceReplacementPrunes() async throws {
        try await withFixture { fixture, monitor, log in
            try (Self.baseContent + "\nline4").write(to: fixture.urlB, atomically: true, encoding: .utf8)
            let recorded = await awaitCondition(timeout: 3.0) {
                monitor.indicator(for: fixture.tabB) != nil
            }
            #expect(recorded)

            // The Files browser replaces a tab's file in place: same id, new URL.
            let replacementURL = fixture.directory.url.appendingPathComponent("c.md")
            try Self.baseContent.write(to: replacementURL, atomically: false, encoding: .utf8)
            let replacedTab = DocumentPane(
                id: fixture.tabB.id, fileURL: replacementURL, title: "c.md")
            monitor.sync(
                tabs: [fixture.tabA, replacedTab],
                selectedTabID: fixture.tabA.id,
                cachedSource: { _ in nil }
            )
            #expect(monitor.indicator(for: fixture.tabB) == nil, "old-path indicator must prune")
            #expect(monitor.indicator(for: replacedTab) == nil)

            // Edits to the abandoned file must not reach the replaced tab.
            let announcementsBefore = log.messages.count
            try (Self.baseContent + "\nline5").write(to: fixture.urlB, atomically: true, encoding: .utf8)
            try await Task.sleep(nanoseconds: 700_000_000)
            #expect(monitor.indicator(for: replacedTab) == nil)
            #expect(log.messages.count == announcementsBefore)
        }
    }

    @Test("a re-edit back to previously announced content announces again after a dismiss")
    func reEditAfterRevertAnnouncesAgain() async throws {
        try await withFixture { fixture, monitor, log in
            let edited = Self.baseContent + "\nline4"
            try edited.write(to: fixture.urlB, atomically: true, encoding: .utf8)
            _ = await awaitCondition(timeout: 3.0) {
                monitor.indicator(for: fixture.tabB) != nil
            }
            #expect(log.messages.count == 1)

            try Self.baseContent.write(to: fixture.urlB, atomically: true, encoding: .utf8)
            _ = await awaitCondition(timeout: 3.0) {
                monitor.indicator(for: fixture.tabB) == nil
            }

            // The same content as the first edit is a genuinely new revision
            // after the dismiss; the announce dedup must not swallow it.
            try edited.write(to: fixture.urlB, atomically: true, encoding: .utf8)
            let reRecorded = await awaitCondition(timeout: 3.0) {
                monitor.indicator(for: fixture.tabB) != nil && log.messages.count == 2
            }
            #expect(reRecorded)
        }
    }

    @Test("reconcile diffs against the baseline captured at selection time")
    func reconcileUsesCapturedBaseline() async throws {
        try await withFixture { fixture, monitor, log in
            monitor.stopAll()
            let edited = Self.baseContent + "\nline4\nline5"
            try edited.write(to: fixture.urlB, atomically: true, encoding: .utf8)

            monitor.sync(
                tabs: [fixture.tabA, fixture.tabB],
                selectedTabID: fixture.tabB.id,
                cachedSource: { _ in Self.baseContent }
            )
            monitor.reconcile(tab: fixture.tabB)
            // Simulate the remounting pane's render winning the race: the
            // live baseline advances to the on-disk content before the
            // reconcile read commits. The captured baseline must still win.
            monitor.noteRenderCompleted(source: edited, for: fixture.tabB)

            let recorded = await awaitCondition(timeout: 3.0) {
                self.exactDiff(monitor.indicator(for: fixture.tabB)) == LineDiffCount(added: 2, removed: 0)
            }
            #expect(recorded)
            #expect(log.messages.count == 1)
        }
    }

    @Test("recordSelected does not re-announce the identical revision a reconcile just recorded")
    func recordSelectedDeduplicatesReconcileAnnouncement() async throws {
        try await withFixture { fixture, monitor, log in
            monitor.stopAll()
            let edited = Self.baseContent + "\nline4"
            try edited.write(to: fixture.urlB, atomically: true, encoding: .utf8)
            monitor.sync(
                tabs: [fixture.tabA, fixture.tabB],
                selectedTabID: fixture.tabB.id,
                cachedSource: { _ in Self.baseContent }
            )
            monitor.reconcile(tab: fixture.tabB)
            _ = await awaitCondition(timeout: 3.0) {
                monitor.indicator(for: fixture.tabB) != nil
            }
            #expect(log.messages.count == 1)

            // The mounted pane re-reporting the same diff refreshes the
            // indicator but must not speak a second time.
            monitor.recordSelected(.exact(LineDiffCount(added: 1, removed: 0)), for: fixture.tabB)
            #expect(log.messages.count == 1)

            // A genuinely different revision announces normally.
            monitor.recordSelected(.exact(LineDiffCount(added: 3, removed: 1)), for: fixture.tabB)
            #expect(log.messages.count == 2)
        }
    }

    // MARK: - Registry

    @Test("registry returns one monitor per group and prune stops dead groups")
    func registryIdentityAndPrune() async throws {
        let directory = try TemporaryDirectory(prefix: "DocumentRevisionMonitorTests")
        defer { withExtendedLifetime(directory) {} }
        let url = directory.url.appendingPathComponent("a.md")
        try Self.baseContent.write(to: url, atomically: false, encoding: .utf8)
        let selected = DocumentPane(
            fileURL: directory.url.appendingPathComponent("other.md"), title: "other.md")
        try Self.baseContent.write(to: selected.fileURL, atomically: false, encoding: .utf8)
        let tab = DocumentPane(fileURL: url, title: "a.md")

        let groupID = UUID()
        let monitor = DocumentRevisionMonitorRegistry.monitor(for: groupID)
        // Survives an unmount: the registry hands back the same instance, so
        // a session switch does not reset baselines or indicators.
        #expect(DocumentRevisionMonitorRegistry.monitor(for: groupID) === monitor)
        #expect(DocumentRevisionMonitorRegistry.monitor(for: UUID()) !== monitor)

        monitor.announce = { _ in }
        monitor.selfWriteContext = { _, _ in nil }
        monitor.sync(
            tabs: [selected, tab],
            selectedTabID: selected.id,
            cachedSource: { _ in Self.baseContent }
        )
        try await Task.sleep(nanoseconds: 50_000_000)

        // Pruning a closed group stops its watchers: subsequent edits no
        // longer record.
        DocumentRevisionMonitorRegistry.prune(keeping: [])
        try (Self.baseContent + "\nline4").write(to: url, atomically: true, encoding: .utf8)
        try await Task.sleep(nanoseconds: 700_000_000)
        #expect(monitor.indicator(for: tab) == nil)
    }

    // MARK: - Selected-pane passthrough

    @Test("recordSelected records and announces")
    func recordSelectedAnnounces() async throws {
        let directory = try TemporaryDirectory(prefix: "DocumentRevisionMonitorTests")
        defer { withExtendedLifetime(directory) {} }
        let url = directory.url.appendingPathComponent("a.md")
        try Self.baseContent.write(to: url, atomically: false, encoding: .utf8)
        let tab = DocumentPane(fileURL: url, title: "a.md")

        let log = AnnouncementLog()
        let monitor = makeMonitor(log: log)
        monitor.sync(tabs: [tab], selectedTabID: tab.id, cachedSource: { _ in Self.baseContent })

        monitor.recordSelected(.exact(LineDiffCount(added: 1, removed: 2)), for: tab)
        #expect(exactDiff(monitor.indicator(for: tab)) == LineDiffCount(added: 1, removed: 2))
        #expect(log.messages.count == 1)
        #expect(log.messages.first?.contains("a.md") == true)
        monitor.stopAll()
    }
}
