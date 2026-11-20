import AwesoMuxConfig
import Foundation
import Testing

@testable import awesoMux

@MainActor
@Suite("Setup wizard regressions")
struct SetupWizardRegressionTests {
    /// Failure mode: with the wizard open, a queued workspace notification
    /// shows the automatic permission prompt before the Agents step asks.
    /// A regression either touches the real notification center (crash in the
    /// unbundled runner) or runs the explanation alert's modal (hang).
    @Test func automaticAuthorizationWaitsForWizard() {
        let bridge = WorkspaceNotificationBridge(preferencesProvider: {
            NotificationPreferences(
                muted: false, sound: false, respectDoNotDisturb: false, notifyOnNeedsAttention: true)
        })
        bridge.defersAutomaticAuthorization = { true }

        bridge.requestAuthorizationWithExplanationIfNeeded()
        #expect(!bridge.isAuthorizationRequestInFlight)

        // The wizard opened while the status fetch was in flight.
        bridge.handlePrimeStatus(.notDetermined)
        #expect(!bridge.isAuthorizationRequestInFlight)
    }

    /// Failure mode: a custom terminal background previews a catalog color.
    @Test func customBackgroundPreviewsSavedColor() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("setup-wizard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppSettingsStore(
            fileStore: ConfigFileStore(configURL: directory.appendingPathComponent("config.toml")),
            legacySnapshotProvider: { nil })
        store.appearance.update {
            $0.terminalBackgroundMode = .custom
            $0.terminalBackgroundColor = "#123456"
        }

        #expect(SetupWizardCopy.themeBackground(store: store, colorScheme: .dark) == "#123456")
    }
}
