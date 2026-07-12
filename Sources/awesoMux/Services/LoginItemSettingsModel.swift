import Foundation
import Observation
import ServiceManagement

struct LoginItemService {
    var status: () -> SMAppService.Status
    var register: () throws -> Void
    var unregister: () throws -> Void

    @MainActor static let mainApp = LoginItemService(
        status: { SMAppService.mainApp.status },
        register: { try SMAppService.mainApp.register() },
        unregister: { try SMAppService.mainApp.unregister() }
    )
}

@MainActor
@Observable
final class LoginItemSettingsModel {
    enum DisplayStatus: Equatable {
        case unknown
        case off
        case on
        case needsApproval
        case unavailable
    }

    private(set) var status: DisplayStatus = .unknown
    private(set) var errorMessage: String?

    @ObservationIgnored private let service: LoginItemService

    init(service: LoginItemService = .mainApp) {
        self.service = service
    }

    var isRequested: Bool {
        status == .on || status == .needsApproval
    }

    var statusLabel: String {
        switch status {
        case .unknown:
            String(localized: "Checking…", comment: "Settings label while the Open at Login status is being fetched.")
        case .off:
            String(localized: "Off", comment: "Settings label when Open at Login is disabled.")
        case .on:
            String(localized: "On", comment: "Settings label when Open at Login is enabled.")
        case .needsApproval:
            String(localized: "Needs approval", comment: "Settings label when Open at Login requires approval in System Settings.")
        case .unavailable:
            String(localized: "Unavailable", comment: "Settings label when the app cannot be registered as a login item.")
        }
    }

    var statusHint: String {
        switch status {
        case .unknown:
            String(
                localized: "Checking whether macOS is set to open awesoMux at login.",
                comment: "Settings hint while the Open at Login status is being fetched."
            )
        case .off:
            String(
                localized: "awesoMux is not registered as a macOS login item.",
                comment: "Settings hint when Open at Login is disabled."
            )
        case .on:
            String(
                localized: "macOS will open awesoMux when you log in.",
                comment: "Settings hint when Open at Login is enabled."
            )
        case .needsApproval:
            String(
                localized: "macOS has the login item registered, but you still need to approve awesoMux in System Settings > General > Login Items.",
                comment: "Settings hint when Open at Login requires approval in System Settings."
            )
        case .unavailable:
            String(
                localized: "macOS cannot find this app bundle as a login item. Try from a built awesoMux.app bundle.",
                comment: "Settings hint when the current app cannot be registered as a login item."
            )
        }
    }

    var accessibilityValue: String {
        if let errorMessage {
            return String(
                localized: "\(statusLabel). \(errorMessage)",
                comment: "VoiceOver value combining the Open at Login status with its latest error."
            )
        }
        return statusLabel
    }

func refresh(clearsResolvedError: Bool = true) {
    status = Self.displayStatus(for: service.status())
    if clearsResolvedError && (status == .on || status == .off) {
        errorMessage = nil
    }
}

    func setRequested(_ requested: Bool) {
        errorMessage = nil
        do {
            if requested {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            errorMessage = Self.failureMessage(for: error, requested: requested)
        }
        refresh(clearsResolvedError: false)
    }

    nonisolated static func displayStatus(for status: SMAppService.Status) -> DisplayStatus {
        switch status {
        case .enabled:
            .on
        case .requiresApproval:
            .needsApproval
        case .notRegistered:
            .off
        case .notFound:
            .unavailable
        @unknown default:
            .unknown
        }
    }

    nonisolated static func failureMessage(for error: Error, requested: Bool) -> String {
        if requested {
            return String(
                localized: "Could not turn on Open at Login. Open System Settings > General > Login Items and allow awesoMux, then try again. \(error.localizedDescription)",
                comment: "Error shown when registering awesoMux as a login item fails."
            )
        }
        return String(
            localized: "Could not turn off Open at Login. Open System Settings > General > Login Items and remove awesoMux, then try again. \(error.localizedDescription)",
            comment: "Error shown when unregistering awesoMux as a login item fails."
        )
    }
}
