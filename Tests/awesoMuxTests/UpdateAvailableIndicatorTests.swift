import AwesoMuxTestSupport
import Foundation
import Testing

@testable import awesoMux

@Suite("Update available indicator")
struct UpdateAvailableIndicatorTests {
    @Test("does not render a reminder without an available version")
    func doesNotRenderWithoutAvailableVersion() {
        #expect(
            UpdateAvailableIndicatorContent(
                availableVersion: nil,
                displayMode: .expanded
            ) == nil
        )
    }

    @Test("expanded reminder exposes versioned accessible update choices")
    func expandedReminderExposesVersionedAccessibleChoices() throws {
        let content = try #require(
            UpdateAvailableIndicatorContent(
                availableVersion: "2.0",
                displayMode: .expanded
            )
        )

        #expect(content.title == "Update Available")
        #expect(content.accessibilityLabel.contains("2.0"))
        #expect(content.actions == [.update, .skipForNow])
    }

    @Test("collapsed reminder remains accessible with the available version")
    func collapsedReminderRemainsAccessible() throws {
        let content = try #require(
            UpdateAvailableIndicatorContent(
                availableVersion: "2.0",
                displayMode: .collapsed
            )
        )

        #expect(content.usesCollapsedPresentation)
        #expect(content.accessibilityLabel.contains("2.0"))
    }

    @Test("update action forwards the explicit Sparkle check") @MainActor
    func updateActionForwardsExplicitSparkleCheck() throws {
        var checks = 0
        let fixture = try configuredBundle()
        let controller = UpdateController(
            runtimeProfile: .production,
            bundle: fixture.bundle,
            checkForUpdatesAction: { checks += 1 }
        )

        UpdateAvailableIndicatorAction.update.perform(using: controller)

        #expect(checks == 1)
    }

    @Test("skip for now clears only the current reminder") @MainActor
    func skipForNowClearsCurrentReminder() throws {
        let fixture = try configuredBundle()
        let controller = UpdateController(
            runtimeProfile: .production,
            bundle: fixture.bundle,
            checkForUpdatesAction: {}
        )
        controller.handleUpdatePresentation(displayVersion: "2.0", handledBySparkle: false)

        UpdateAvailableIndicatorAction.skipForNow.perform(using: controller)

        #expect(controller.availableVersion == nil)
    }

    private func configuredBundle() throws -> UpdateFixture {
        let directory = try TemporaryDirectory(prefix: "awesomux-update-available-indicator")
        let bundleURL = directory.url.appending(path: "UpdateFixture.app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let info: [String: String] = [
            "CFBundleIdentifier": "com.example.awesomux-tests",
            "SUFeedURL": "https://example.com/appcast.xml",
            "SUPublicEDKey": "public-key",
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try data.write(to: bundleURL.appending(path: "Info.plist"))
        return UpdateFixture(directory: directory, bundle: try #require(Bundle(url: bundleURL)))
    }

    private final class UpdateFixture {
        let directory: TemporaryDirectory
        let bundle: Bundle

        init(directory: TemporaryDirectory, bundle: Bundle) {
            self.directory = directory
            self.bundle = bundle
        }
    }
}
