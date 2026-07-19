import AwesoMuxConfig
import Foundation
import Testing

@testable import awesoMux

@MainActor
@Suite("LocalAnalyticsClient")
struct LocalAnalyticsClientTests {
    private struct Fixture {
        let root: URL
        let store: AnalyticsEventLogStore
        let client: LocalAnalyticsClient
        let setConsent: (AnalyticsConfig.ConsentLevel) -> Void

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    @MainActor
    private static func makeFixture(
        consent initial: AnalyticsConfig.ConsentLevel
    ) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "analytics-client-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let box = ConsentBox(level: initial)
        let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
        let store = AnalyticsEventLogStore(rootDirectoryURL: root, now: { fixedNow })
        let client = LocalAnalyticsClient(
            logStore: store,
            consent: { box.level },
            now: { fixedNow }
        )
        return Fixture(root: root, store: store, client: client, setConsent: { box.level = $0 })
    }

    @MainActor
    private final class ConsentBox {
        var level: AnalyticsConfig.ConsentLevel
        init(level: AnalyticsConfig.ConsentLevel) { self.level = level }
    }

    @Test("consent off records nothing at all")
    func offIsNoOp() throws {
        let fixture = try Self.makeFixture(consent: .off)
        defer { fixture.cleanUp() }

        fixture.client.capture(.testPing)
        #expect(fixture.store.entries.isEmpty)
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.root.appending(path: "analytics/events.jsonl").path
            ))
    }

    @Test("accepted event logs as dropped delivery_unavailable")
    func acceptedEventLogged() throws {
        let fixture = try Self.makeFixture(consent: .errorReports)
        defer { fixture.cleanUp() }

        fixture.client.capture(.testPing)
        let entry = try #require(fixture.store.entries.first)
        #expect(fixture.store.entries.count == 1)
        #expect(entry.name == .testPing)
        #expect(entry.consentLevel == .errorReports)
        #expect(entry.status == .dropped)
        #expect(entry.dropReason == .deliveryUnavailable)
        #expect(entry.provider == "posthog")
        #expect(entry.schemaVersion == analyticsSchemaVersion)
        #expect(entry.properties[.consentLevel] == .token("error_reports"))
    }

    @Test("consent reconciliation restores enabled identity without inventing an event")
    func reconcilePersistedConsent() throws {
        let fixture = try Self.makeFixture(consent: .errorReports)
        defer { fixture.cleanUp() }

        fixture.client.reconcileConsent(level: .errorReports)

        #expect(
            FileManager.default.fileExists(
                atPath: fixture.root.appending(path: "analytics/distinct_id").path
            )
        )
        #expect(fixture.store.entries.isEmpty)
    }

    @Test("optIn creates distinct id and logs the consent change")
    func optInLifecycle() throws {
        let fixture = try Self.makeFixture(consent: .off)
        defer { fixture.cleanUp() }

        fixture.setConsent(.productUsage)
        fixture.client.optIn(level: .productUsage)

        #expect(
            FileManager.default.fileExists(
                atPath: fixture.root.appending(path: "analytics/distinct_id").path
            ))
        let entry = try #require(fixture.store.entries.first)
        #expect(entry.name == .settingsChanged)
        #expect(entry.properties[.settingsArea] == .token("analytics"))
        #expect(entry.properties[.consentLevel] == .token("product_usage"))
    }

    @Test("optOut with delete removes local state; id rotates on next opt-in")
    func optOutDeletes() throws {
        let fixture = try Self.makeFixture(consent: .errorReports)
        defer { fixture.cleanUp() }

        fixture.client.capture(.testPing)
        let originalID = fixture.store.distinctID()

        fixture.setConsent(.off)
        fixture.client.optOut(deleteLocalState: true)
        #expect(fixture.store.entries.isEmpty)

        fixture.setConsent(.errorReports)
        fixture.client.optIn(level: .errorReports)
        #expect(fixture.store.distinctID() != originalID)
    }

    @Test("optOut keeping data preserves the log")
    func optOutKeepsData() throws {
        let fixture = try Self.makeFixture(consent: .errorReports)
        defer { fixture.cleanUp() }

        fixture.client.capture(.testPing)
        fixture.setConsent(.off)
        fixture.client.optOut(deleteLocalState: false)
        #expect(fixture.store.entries.count == 1)
    }
}
