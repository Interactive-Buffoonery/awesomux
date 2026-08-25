import AwesoMuxTestSupport
import Foundation
import Sparkle
import Testing

@testable import awesoMux

@Suite("Update controller")
struct UpdateControllerTests {
    @Test("non-production profiles never enable Sparkle") @MainActor
    func nonProductionProfilesNeverEnableSparkle() throws {
        let fixture = try configuredBundle()

        for profile in [
            AppRuntimeProfile.development(worktreeID: nil),
            AppRuntimeProfile.test(processID: 42),
            AppRuntimeProfile.resolve(bundleIdentifier: "com.example.unknown"),
        ] {
            let controller = UpdateController(
                runtimeProfile: profile,
                bundle: fixture.bundle,
                checkForUpdatesAction: {}
            )

            #expect(!controller.isEnabled)
            #expect(!controller.canCheckForUpdates)
        }
    }

    @Test("production requires both release updater values") @MainActor
    func productionRequiresBothReleaseUpdaterValues() throws {
        for fixture in try [
            configuredBundle(feedURL: nil),
            configuredBundle(publicKey: nil),
            configuredBundle(feedURL: "", publicKey: ""),
        ] {
            let controller = UpdateController(
                runtimeProfile: .production,
                bundle: fixture.bundle,
                checkForUpdatesAction: {}
            )

            #expect(!controller.isEnabled)
            #expect(!controller.canCheckForUpdates)
        }
    }

    @Test("a configured production release enables explicit checks") @MainActor
    func configuredProductionReleaseEnablesExplicitChecks() throws {
        let fixture = try configuredBundle()
        let controller = UpdateController(
            runtimeProfile: .production,
            bundle: fixture.bundle,
            checkForUpdatesAction: {}
        )

        #expect(controller.isEnabled)
        #expect(controller.canCheckForUpdates)
    }

    @Test("scheduled updates record a display version until the session ends") @MainActor
    func scheduledUpdatesRecordDisplayVersionUntilSessionEnds() throws {
        let fixture = try configuredBundle()
        let controller = UpdateController(
            runtimeProfile: .production,
            bundle: fixture.bundle,
            checkForUpdatesAction: {}
        )

        controller.recordScheduledUpdate(displayVersion: "2.0")
        #expect(controller.availableVersion == "2.0")

        controller.standardUserDriverWillFinishUpdateSession()
        #expect(controller.availableVersion == nil)
    }

    @Test("scheduled checks never let Sparkle present an update") @MainActor
    func scheduledChecksNeverLetSparklePresentAnUpdate() throws {
        let fixture = try configuredBundle()
        let controller = UpdateController(
            runtimeProfile: .production,
            bundle: fixture.bundle,
            checkForUpdatesAction: {}
        )

        #expect(controller.supportsGentleScheduledUpdateReminders)
        #expect(
            !controller.standardUserDriverShouldHandleShowingScheduledUpdate(
                SUAppcastItem.empty(),
                andInImmediateFocus: true
            ))
    }

    @Test("skip for now hides the available update") @MainActor
    func skipForNowHidesAvailableUpdate() throws {
        let fixture = try configuredBundle()
        let controller = UpdateController(
            runtimeProfile: .production,
            bundle: fixture.bundle,
            checkForUpdatesAction: {}
        )
        controller.recordScheduledUpdate(displayVersion: "2.0")

        controller.skipAvailableUpdate()

        #expect(controller.availableVersion == nil)
    }

    @Test("explicit checks forward only through the enabled updater") @MainActor
    func explicitChecksForwardOnlyThroughEnabledUpdater() throws {
        var checks = 0
        let fixture = try configuredBundle()
        let controller = UpdateController(
            runtimeProfile: .production,
            bundle: fixture.bundle,
            checkForUpdatesAction: { checks += 1 }
        )

        controller.checkForUpdates()

        #expect(checks == 1)
    }

    private func configuredBundle(
        feedURL: String? = "https://example.com/appcast.xml",
        publicKey: String? = "public-key"
    ) throws -> UpdateFixture {
        let directory = try TemporaryDirectory(prefix: "awesomux-update-controller")
        let bundleURL = directory.url.appending(path: "UpdateFixture.app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        var info: [String: Any] = ["CFBundleIdentifier": "com.example.awesomux-tests"]
        if let feedURL {
            info["SUFeedURL"] = feedURL
        }
        if let publicKey {
            info["SUPublicEDKey"] = publicKey
        }
        let data = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try data.write(to: bundleURL.appending(path: "Info.plist"))
        return UpdateFixture(
            directory: directory,
            bundle: try #require(Bundle(url: bundleURL))
        )
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
