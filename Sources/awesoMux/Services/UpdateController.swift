import Foundation
import Observation
import Sparkle

@MainActor
@Observable
final class UpdateController: NSObject, @preconcurrency SPUStandardUserDriverDelegate {
    typealias ReminderScheduler =
        @MainActor (
            _ delay: TimeInterval,
            _ action: @escaping @MainActor () -> Void
        ) -> @MainActor () -> Void

    private(set) var isEnabled: Bool
    private(set) var availableVersion: String?
    private(set) var canCheckForUpdates: Bool

    @ObservationIgnored private var updaterController: SPUStandardUpdaterController?
    @ObservationIgnored private var canCheckForUpdatesObservation: NSKeyValueObservation?
    @ObservationIgnored private var checkForUpdatesAction: (() -> Void)?
    @ObservationIgnored private var updateCheckInterval: (() -> TimeInterval)?
    @ObservationIgnored private let scheduleReminder: ReminderScheduler
    @ObservationIgnored private let announce: (String) -> Void
    @ObservationIgnored private var cancelScheduledReminder: (@MainActor () -> Void)?
    @ObservationIgnored private var skippedVersion: String?

    init(
        runtimeProfile: AppRuntimeProfile = .current,
        bundle: Bundle = .main,
        checkForUpdatesAction: (() -> Void)? = nil,
        updateCheckInterval: (() -> TimeInterval)? = nil,
        scheduleReminder: @escaping ReminderScheduler = UpdateController.scheduleReminder,
        announce: @escaping (String) -> Void = { TerminalAccessibilityAnnouncer.announce($0) }
    ) {
        isEnabled =
            runtimeProfile == .production
            && Self.hasReleaseConfiguration(in: bundle)
        availableVersion = nil
        canCheckForUpdates = false
        self.checkForUpdatesAction = nil
        self.updateCheckInterval = updateCheckInterval
        self.scheduleReminder = scheduleReminder
        self.announce = announce
        cancelScheduledReminder = nil
        skippedVersion = nil
        super.init()

        guard isEnabled else {
            return
        }
        if let checkForUpdatesAction {
            self.checkForUpdatesAction = checkForUpdatesAction
            canCheckForUpdates = true
            return
        }

        let updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: self
        )
        self.updaterController = updaterController
        canCheckForUpdates = updaterController.updater.canCheckForUpdates
        canCheckForUpdatesObservation = updaterController.updater.observe(
            \.canCheckForUpdates,
            options: [.new]
        ) { [weak self] _, change in
            guard let canCheckForUpdates = change.newValue else {
                return
            }
            Task { @MainActor [weak self] in
                self?.handleCanCheckForUpdatesChange(canCheckForUpdates)
            }
        }
        self.updateCheckInterval = { [weak updater = updaterController.updater] in
            updater?.updateCheckInterval ?? 0
        }
        self.checkForUpdatesAction = { [weak updaterController] in
            updaterController?.checkForUpdates(nil)
        }
    }

    func checkForUpdates() {
        guard canCheckForUpdates else {
            return
        }
        checkForUpdatesAction?()
    }

    func handleCanCheckForUpdatesChange(_ canCheckForUpdates: Bool) {
        self.canCheckForUpdates = canCheckForUpdates
    }

    func skipAvailableUpdate() {
        guard let version = availableVersion else {
            return
        }
        clearScheduledReminder()
        skippedVersion = version
        availableVersion = nil
        guard let interval = updateCheckInterval?(), interval > 0 else {
            skippedVersion = nil
            return
        }
        cancelScheduledReminder = scheduleReminder(interval) { [weak self] in
            guard let self, self.availableVersion == nil, self.skippedVersion == version else {
                return
            }
            self.cancelScheduledReminder = nil
            self.skippedVersion = nil
            self.showAvailableVersion(version)
        }
    }

    var supportsGentleScheduledUpdateReminders: Bool {
        true
    }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        handleUpdatePresentation(
            displayVersion: update.displayVersionString,
            handledBySparkle: handleShowingUpdate
        )
    }

    func handleUpdatePresentation(displayVersion: String, handledBySparkle: Bool) {
        guard !handledBySparkle else {
            return
        }
        clearScheduledReminder()
        showAvailableVersion(displayVersion)
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        clearAvailableUpdate()
    }

    func standardUserDriverWillFinishUpdateSession() {
        clearAvailableUpdate()
    }

    private func showAvailableVersion(_ version: String) {
        guard availableVersion != version else {
            return
        }
        availableVersion = version
        announce(
            String(
                localized: "Update available, version \(version)",
                comment: "VoiceOver announcement when an update becomes available"
            ))
    }

    private func clearAvailableUpdate() {
        clearScheduledReminder()
        availableVersion = nil
    }

    private func clearScheduledReminder() {
        cancelScheduledReminder?()
        cancelScheduledReminder = nil
        skippedVersion = nil
    }

    private static func scheduleReminder(
        after delay: TimeInterval,
        action: @escaping @MainActor () -> Void
    ) -> @MainActor () -> Void {
        let workItem = DispatchWorkItem {
            MainActor.assumeIsolated {
                action()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        return { workItem.cancel() }
    }

    private static func hasReleaseConfiguration(in bundle: Bundle) -> Bool {
        ["SUFeedURL", "SUPublicEDKey"].allSatisfy { key in
            guard let value = bundle.object(forInfoDictionaryKey: key) as? String else {
                return false
            }
            return !value.isEmpty
        }
    }
}
