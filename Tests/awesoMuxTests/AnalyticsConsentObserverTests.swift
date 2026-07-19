import AwesoMuxConfig
import Foundation
import Testing

@testable import awesoMux

@MainActor
@Suite("Analytics consent observer")
struct AnalyticsConsentObserverTests {
    @MainActor
    private final class ClientSpy: AnalyticsClient {
        private(set) var reconciledLevels: [AnalyticsConfig.ConsentLevel] = []

        func reconcileConsent(level: AnalyticsConfig.ConsentLevel) {
            reconciledLevels.append(level)
        }

        func capture(_ input: AnalyticsEventInput) {}
        func optIn(level: AnalyticsConfig.ConsentLevel) {}
        func optOut(deleteLocalState: Bool) -> Bool { true }
        func deleteLocalAnalyticsState() -> Bool { true }
        func flushForTermination() {}
    }

    @MainActor
    private final class ProviderSpy: AnalyticsDeliveryProvider {
        private(set) var captureCount = 0
        private(set) var cancelCount = 0

        func capture(
            _ event: SanitizedAnalyticsEvent,
            anonymousID: UUID,
            timestamp: Date
        ) -> AnalyticsProviderCaptureResult {
            captureCount += 1
            return .submitted
        }

        func cancelInFlightRequests() {
            cancelCount += 1
        }
    }

    @Test("tracks persisted changes and fails closed on invalid config without a view")
    func observesAppLifetimeConsent() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "analytics-consent-observer-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let resolver = ConfigPathResolver(homeDirectory: root)
        let settings = AppSettingsStore(
            fileStore: ConfigFileStore(pathResolver: resolver),
            legacySnapshotProvider: { nil }
        )
        let client = ClientSpy()
        let observer = AnalyticsConsentObserver(settings: settings, client: client)

        observer.start()
        #expect(client.reconciledLevels == [.off])

        settings.analytics.update { $0.consentLevel = .productUsage }
        #expect(settings.analytics.value.consentLevel == .productUsage)
        try await Self.waitUntil { client.reconciledLevels.last == .productUsage }

        try Data("[analytics]\nconsent_level = [\n".utf8).write(
            to: resolver.configFileURL,
            options: .atomic
        )
        settings.reloadFromDisk()
        try await Self.waitUntil { client.reconciledLevels.last == .off }

        #expect(client.reconciledLevels == [.off, .productUsage, .off])
        _ = observer
    }

    @Test("tracks retention changes without a view")
    func observesRetention() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "analytics-retention-observer-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = AppSettingsStore(
            fileStore: ConfigFileStore(
                pathResolver: ConfigPathResolver(homeDirectory: root)
            ),
            legacySnapshotProvider: { nil }
        )
        let client = ClientSpy()
        var retainedValues: [Bool] = []
        let observer = AnalyticsConsentObserver(
            settings: settings,
            client: client,
            reconcileRetention: { retainedValues.append($0) }
        )
        observer.start()
        #expect(retainedValues == [true])

        settings.analytics.update { $0.retainLocalEventLog = false }
        try await Self.waitUntil { retainedValues.last == false }

        #expect(retainedValues.last == false)
        _ = observer
    }

    @Test("invalid disk config blocks pipeline capture")
    func invalidConfigBlocksCapture() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "analytics-invalid-config-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let resolver = ConfigPathResolver(homeDirectory: root)
        let settings = AppSettingsStore(
            fileStore: ConfigFileStore(pathResolver: resolver),
            legacySnapshotProvider: { nil }
        )
        settings.analytics.update { $0.consentLevel = .errorReports }
        let provider = ProviderSpy()
        let logStore = AnalyticsEventLogStore(
            rootDirectoryURL: root.appending(path: "Support", directoryHint: .isDirectory)
        )
        let client = AnalyticsPipelineClient(
            logStore: logStore,
            consent: { AnalyticsConsentObserver.effectiveConsent(for: settings) },
            provider: provider
        )
        let observer = AnalyticsConsentObserver(settings: settings, client: client)
        observer.start()
        client.capture(.testPing)
        #expect(provider.captureCount == 1)
        #expect(logStore.entries.count == 1)

        try Data("[analytics]\nconsent_level = [\n".utf8).write(
            to: resolver.configFileURL,
            options: .atomic
        )
        settings.reloadFromDisk()
        #expect(settings.isDiskConfigInvalid)
        client.capture(.testPing)

        #expect(provider.captureCount == 1)
        #expect(provider.cancelCount == 1)
        #expect(logStore.entries.count == 1)
        _ = observer
    }

    private static func waitUntil(_ condition: @escaping @MainActor () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }
}
