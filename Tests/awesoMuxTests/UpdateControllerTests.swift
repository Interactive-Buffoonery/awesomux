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

    @Test("Sparkle availability changes update explicit-check state") @MainActor
    func sparkleAvailabilityChangesUpdateExplicitCheckState() throws {
        var checks = 0
        let fixture = try configuredBundle()
        let controller = UpdateController(
            runtimeProfile: .production,
            bundle: fixture.bundle,
            checkForUpdatesAction: { checks += 1 }
        )

        controller.handleCanCheckForUpdatesChange(false)
        controller.checkForUpdates()
        #expect(!controller.canCheckForUpdates)
        #expect(checks == 0)

        controller.handleCanCheckForUpdatesChange(true)
        controller.checkForUpdates()
        #expect(controller.canCheckForUpdates)
        #expect(checks == 1)
    }

    @Test("scheduled updates record a display version until the session ends") @MainActor
    func scheduledUpdatesRecordDisplayVersionUntilSessionEnds() throws {
        let fixture = try configuredBundle()
        let controller = UpdateController(
            runtimeProfile: .production,
            bundle: fixture.bundle,
            checkForUpdatesAction: {}
        )

        controller.handleUpdatePresentation(displayVersion: "2.0", handledBySparkle: false)
        #expect(controller.availableVersion == "2.0")

        controller.handleUpdatePresentation(displayVersion: "3.0", handledBySparkle: true)
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
        controller.handleUpdatePresentation(displayVersion: "2.0", handledBySparkle: false)

        controller.skipAvailableUpdate()

        #expect(controller.availableVersion == nil)
    }

    @Test("skip for now restores the reminder at the next update-check interval") @MainActor
    func skipForNowRestoresReminderAtNextUpdateCheckInterval() throws {
        var scheduledDelay: TimeInterval?
        var reminder: (@MainActor () -> Void)?
        let fixture = try configuredBundle()
        let controller = UpdateController(
            runtimeProfile: .production,
            bundle: fixture.bundle,
            checkForUpdatesAction: {},
            updateCheckInterval: { 42 },
            scheduleReminder: { delay, action in
                scheduledDelay = delay
                reminder = action
                return {}
            }
        )
        controller.handleUpdatePresentation(displayVersion: "2.0", handledBySparkle: false)

        controller.skipAvailableUpdate()

        #expect(controller.availableVersion == nil)
        #expect(scheduledDelay == 42)
        reminder?()
        #expect(controller.availableVersion == "2.0")
    }

    @Test("new update state cancels and supersedes a skipped reminder") @MainActor
    func newUpdateStateCancelsSkippedReminder() throws {
        var reminder: (@MainActor () -> Void)?
        var cancellations = 0
        let fixture = try configuredBundle()
        let controller = UpdateController(
            runtimeProfile: .production,
            bundle: fixture.bundle,
            checkForUpdatesAction: {},
            updateCheckInterval: { 42 },
            scheduleReminder: { _, action in
                reminder = action
                return { cancellations += 1 }
            }
        )
        controller.handleUpdatePresentation(displayVersion: "2.0", handledBySparkle: false)
        controller.skipAvailableUpdate()

        controller.handleUpdatePresentation(displayVersion: "3.0", handledBySparkle: false)
        reminder?()

        #expect(cancellations == 1)
        #expect(controller.availableVersion == "3.0")
        controller.standardUserDriverWillFinishUpdateSession()
        #expect(controller.availableVersion == nil)
    }

    @Test("availability announcements suppress duplicate callbacks") @MainActor
    func availabilityAnnouncementsSuppressDuplicateCallbacks() throws {
        var announcements: [String] = []
        let fixture = try configuredBundle()
        let controller = UpdateController(
            runtimeProfile: .production,
            bundle: fixture.bundle,
            checkForUpdatesAction: {},
            announce: { announcements.append($0) }
        )

        controller.handleUpdatePresentation(displayVersion: "2.0", handledBySparkle: false)
        controller.handleUpdatePresentation(displayVersion: "2.0", handledBySparkle: false)
        controller.handleUpdatePresentation(displayVersion: "3.0", handledBySparkle: false)

        #expect(announcements.count == 2)
        #expect(announcements[0].contains("2.0"))
        #expect(announcements[1].contains("3.0"))
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

    @Test("disabled explicit checks do not forward") @MainActor
    func disabledExplicitChecksDoNotForward() throws {
        var checks = 0
        let fixture = try configuredBundle()
        let controller = UpdateController(
            runtimeProfile: .development(worktreeID: nil),
            bundle: fixture.bundle,
            checkForUpdatesAction: { checks += 1 }
        )

        controller.checkForUpdates()

        #expect(checks == 0)
    }

    @Test("user attention clears a scheduled update") @MainActor
    func userAttentionClearsScheduledUpdate() throws {
        let fixture = try configuredBundle()
        let controller = UpdateController(
            runtimeProfile: .production,
            bundle: fixture.bundle,
            checkForUpdatesAction: {}
        )
        controller.handleUpdatePresentation(displayVersion: "2.0", handledBySparkle: false)
        #expect(controller.availableVersion == "2.0")

        controller.standardUserDriverDidReceiveUserAttention(forUpdate: SUAppcastItem.empty())

        #expect(controller.availableVersion == nil)
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
