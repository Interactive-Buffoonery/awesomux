import AwesoMuxConfig
import Foundation
import Testing

@testable import awesoMux

@MainActor
@Suite("AnalyticsPipelineClient")
struct AnalyticsPipelineClientTests {
    private struct Fixture {
        let root: URL
        let store: AnalyticsEventLogStore
        let provider: ProviderSpy
        let client: AnalyticsPipelineClient
        let consent: ConsentBox

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    @MainActor
    private final class ConsentBox {
        var level: AnalyticsConfig.ConsentLevel
        init(level: AnalyticsConfig.ConsentLevel) { self.level = level }
    }

    @MainActor
    private final class ProviderSpy: AnalyticsDeliveryProvider {
        var result = AnalyticsProviderCaptureResult.submitted
        private(set) var captures: [(SanitizedAnalyticsEvent, UUID, Date)] = []
        private(set) var cancelCount = 0

        func capture(
            _ event: SanitizedAnalyticsEvent,
            anonymousID: UUID,
            timestamp: Date
        ) -> AnalyticsProviderCaptureResult {
            captures.append((event, anonymousID, timestamp))
            return result
        }

        func cancelInFlightRequests() {
            cancelCount += 1
        }
    }

    private static func makeFixture(
        consent initial: AnalyticsConfig.ConsentLevel
    ) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "analytics-client-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let consent = ConsentBox(level: initial)
        let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
        let store = AnalyticsEventLogStore(rootDirectoryURL: root, now: { fixedNow })
        let provider = ProviderSpy()
        let client = AnalyticsPipelineClient(
            logStore: store,
            consent: { consent.level },
            provider: provider,
            now: { fixedNow }
        )
        return Fixture(root: root, store: store, provider: provider, client: client, consent: consent)
    }

    @Test("consent off cancels requests but records nothing")
    func offIsNoOp() throws {
        let fixture = try Self.makeFixture(consent: .off)
        defer { fixture.cleanUp() }

        fixture.client.reconcileConsent(level: .off)
        fixture.client.capture(.testPing)

        #expect(fixture.provider.cancelCount == 1)
        #expect(fixture.provider.captures.isEmpty)
        #expect(fixture.store.entries.isEmpty)
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.root.appending(path: "analytics/distinct_id").path
            ))
    }

    @Test("accepted event submits request and logs only queued")
    func acceptedEventQueued() throws {
        let fixture = try Self.makeFixture(consent: .errorReports)
        defer { fixture.cleanUp() }

        fixture.client.capture(.testPing)

        let entry = try #require(fixture.store.entries.first)
        #expect(fixture.provider.captures.count == 1)
        #expect(entry.name == .testPing)
        #expect(fixture.provider.captures.first?.2 == entry.timestamp)
        #expect(entry.status == .queued)
        #expect(entry.dropReason == nil)
        #expect(entry.properties[.consentLevel] == .token("error_reports"))
    }

    @Test("persisted consent reconciliation stays lazy and invents no event or id")
    func reconcilePersistedConsent() throws {
        let fixture = try Self.makeFixture(consent: .errorReports)
        defer { fixture.cleanUp() }

        fixture.client.reconcileConsent(level: .errorReports)

        #expect(fixture.provider.captures.isEmpty)
        #expect(fixture.store.entries.isEmpty)
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.root.appending(path: "analytics/distinct_id").path
            ))
    }

    @Test("opt in creates id and submits consent change")
    func optInLifecycle() throws {
        let fixture = try Self.makeFixture(consent: .off)
        defer { fixture.cleanUp() }

        fixture.consent.level = .productUsage
        fixture.client.optIn(level: .productUsage)

        let entry = try #require(fixture.store.entries.first)
        #expect(fixture.provider.captures.count == 1)
        #expect(entry.name == .settingsChanged)
        #expect(entry.status == .queued)
        #expect(entry.properties[.settingsArea] == .token("analytics"))
        #expect(entry.properties[.consentLevel] == .token("product_usage"))
    }

    @Test("consent downgrade cancels active requests and applies lower tier")
    func downgradeCancelsRequests() throws {
        let fixture = try Self.makeFixture(consent: .productUsage)
        defer { fixture.cleanUp() }
        fixture.client.capture(.testPing)

        fixture.consent.level = .errorReports
        fixture.client.reconcileConsent(level: .errorReports)
        fixture.client.capture(.testPing)

        #expect(fixture.provider.cancelCount == 1)
        #expect(fixture.provider.captures.count == 2)
        #expect(fixture.store.entries.last?.properties[.consentLevel] == .token("error_reports"))
    }

    @Test("opt out with deletion removes local state and rotates id")
    func optOutDeletes() throws {
        let fixture = try Self.makeFixture(consent: .errorReports)
        defer { fixture.cleanUp() }
        fixture.client.capture(.testPing)
        let originalID = try #require(fixture.store.stableDistinctID())

        fixture.consent.level = .off
        #expect(fixture.client.optOut(deleteLocalState: true))
        #expect(fixture.store.entries.isEmpty)

        fixture.consent.level = .errorReports
        fixture.client.optIn(level: .errorReports)
        #expect(fixture.store.stableDistinctID() != originalID)
    }

    @Test("explicit deletion cancels active requests while keeping consent")
    func explicitDeletion() throws {
        let fixture = try Self.makeFixture(consent: .errorReports)
        defer { fixture.cleanUp() }
        fixture.client.capture(.testPing)
        let originalID = try #require(fixture.store.stableDistinctID())

        #expect(fixture.client.deleteLocalAnalyticsState())

        #expect(fixture.provider.cancelCount == 1)
        #expect(fixture.store.entries.isEmpty)
        fixture.client.capture(.testPing)
        #expect(fixture.store.stableDistinctID() != originalID)
        #expect(fixture.provider.captures.count == 2)
    }

    @Test("opt out keeping data preserves local log and identifier")
    func optOutKeepsData() throws {
        let fixture = try Self.makeFixture(consent: .errorReports)
        defer { fixture.cleanUp() }
        fixture.client.capture(.testPing)
        let originalID = try #require(fixture.store.stableDistinctID())

        fixture.consent.level = .off
        #expect(fixture.client.optOut(deleteLocalState: false))

        #expect(fixture.store.entries.count == 1)
        #expect(fixture.store.stableDistinctID() == originalID)
        #expect(fixture.provider.cancelCount == 1)
    }

    @Test("provider refusal is logged truthfully")
    func captureFailure() throws {
        let fixture = try Self.makeFixture(consent: .errorReports)
        defer { fixture.cleanUp() }
        fixture.provider.result = .rejected(.deliveryUnavailable)

        fixture.client.capture(.testPing)

        #expect(fixture.provider.captures.count == 1)
        #expect(fixture.store.entries.first?.status == .failed)
        #expect(fixture.store.entries.first?.dropReason == .deliveryUnavailable)
    }

    @Test("provider in-flight cap is logged as a dropped event")
    func rateLimited() throws {
        let fixture = try Self.makeFixture(consent: .errorReports)
        defer { fixture.cleanUp() }
        fixture.provider.result = .rejected(.rateLimited)

        fixture.client.capture(.testPing)

        #expect(fixture.store.entries.first?.status == .dropped)
        #expect(fixture.store.entries.first?.dropReason == .rateLimited)
    }

    @Test("unavailable durable identity fails without submission")
    func identityFailure() throws {
        let fixture = try Self.makeFixture(consent: .errorReports)
        defer { fixture.cleanUp() }
        try Data("not a directory".utf8).write(
            to: fixture.root.appending(path: "analytics")
        )

        fixture.client.capture(.testPing)

        #expect(fixture.provider.captures.isEmpty)
        #expect(fixture.store.entries.first?.status == .failed)
        #expect(fixture.store.entries.first?.dropReason == .deliveryUnavailable)
    }

    @Test("termination drains local transparency writes")
    func terminationFlush() async throws {
        let fixture = try Self.makeFixture(consent: .errorReports)
        defer { fixture.cleanUp() }
        fixture.client.capture(.testPing)

        fixture.client.flushForTermination()

        let reloaded = AnalyticsEventLogStore(
            rootDirectoryURL: fixture.root,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        await reloaded.loadIfNeeded()
        #expect(reloaded.entries.count == 1)
    }
}
