import Foundation
import Observation
import Sparkle

@MainActor
@Observable
final class UpdateController: NSObject, @preconcurrency SPUStandardUserDriverDelegate {
    private(set) var isEnabled: Bool
    private(set) var availableVersion: String?

    @ObservationIgnored private var updaterController: SPUStandardUpdaterController?
    @ObservationIgnored private var checkForUpdatesAction: (() -> Void)?

    var canCheckForUpdates: Bool {
        guard isEnabled else {
            return false
        }
        if let updaterController {
            return updaterController.updater.canCheckForUpdates
        }
        return checkForUpdatesAction != nil
    }

    init(
        runtimeProfile: AppRuntimeProfile = .current,
        bundle: Bundle = .main,
        checkForUpdatesAction: (() -> Void)? = nil
    ) {
        isEnabled =
            runtimeProfile == .production
            && Self.hasReleaseConfiguration(in: bundle)
        availableVersion = nil
        self.checkForUpdatesAction = nil
        super.init()

        guard isEnabled else {
            return
        }
        if let checkForUpdatesAction {
            self.checkForUpdatesAction = checkForUpdatesAction
            return
        }

        let updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: self
        )
        self.updaterController = updaterController
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

    func skipAvailableUpdate() {
        availableVersion = nil
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
        availableVersion = displayVersion
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        skipAvailableUpdate()
    }

    func standardUserDriverWillFinishUpdateSession() {
        skipAvailableUpdate()
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
