import AwesoMuxConfig
import Foundation

struct AgentIntegrationSettingsViewModel {
    var installer: AgentIntegrationInstaller
    var homeDirectoryURL: URL

    init(
        installer: AgentIntegrationInstaller = AgentIntegrationInstaller(),
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.installer = installer
        self.homeDirectoryURL = homeDirectoryURL
    }

    // MARK: - Card state derivation (pure)

    /// Derives a card state purely from an observed probe snapshot. All disk
    /// access happened earlier, inside `AgentIntegrationProbeService`; this
    /// function never touches the filesystem so SwiftUI can call it freely
    /// during body evaluation.
    func cardState(
        provider: AgentIntegrationInstallProvider,
        setup: AgentIntegrationSetup,
        probe: AgentIntegrationProviderProbe
    ) -> AgentIntegrationSettingsCardState {
        let manifestStatus = Self.manifestStatus(for: probe.manifest)

        if !setup.enabled {
            var installedPath: String?
            if case .loaded(let recordedPath) = probe.manifest, probe.installedExists, let recordedPath {
                installedPath = recordedPath
            }
            return AgentIntegrationSettingsCardState(
                provider: .init(provider),
                title: provider.displayName,
                subtitle: provider.subtitle,
                binaryPlaceholder: provider.defaultBinaryPath,
                configHomePlaceholder: provider.globalConfigHome(homeDirectory: homeDirectoryURL).path,
                templatePath: probe.templatePath,
                renderedPath: probe.renderedPath,
                globalInstallPath: probe.globalInstallPath,
                binaryValidation: probe.binaryValidation,
                configHomeValidation: probe.configHomeValidation,
                status: manifestStatus ?? .disabled,
                installedPath: installedPath,
                isInstalledGlobally: probe.installedExists,
                isProviderEnabled: false,
                canUninstall: probe.installedExists
            )
        }

        // Status, both path validations, and every derived affordance are
        // decided together here so a published card is always internally
        // coherent — no field of a published card is ever patched alone.
        let status: AgentIntegrationSettingsStatus
        if !probe.templateExists {
            status = .blocked("Bundled template is missing")
        } else if let error = probe.binaryValidation.blockingMessage ?? probe.configHomeValidation.blockingMessage {
            status = .blocked(error)
        } else if let manifestStatus {
            status = manifestStatus
        } else if case .loaded = probe.manifest, probe.installedExists {
            // Byte-compare the live install to the current bundled template so an
            // app update that ships new OpenCode/Pi status code surfaces Repair
            // instead of leaving a silent stale extension in "Installed".
            status = probe.installedContentDiffersFromTemplate ? .updateAvailable : .installed
        } else if probe.renderedExists {
            status = .staged
        } else {
            status = .notInstalled
        }

        return AgentIntegrationSettingsCardState(
            provider: .init(provider),
            title: provider.displayName,
            subtitle: provider.subtitle,
            binaryPlaceholder: provider.defaultBinaryPath,
            configHomePlaceholder: provider.globalConfigHome(homeDirectory: homeDirectoryURL).path,
            templatePath: probe.templatePath,
            renderedPath: probe.renderedPath,
            globalInstallPath: probe.globalInstallPath,
            binaryValidation: probe.binaryValidation,
            configHomeValidation: probe.configHomeValidation,
            status: status,
            installedPath: installedPathIfPresent(probe),
            isInstalledGlobally: probe.installedExists,
            isProviderEnabled: true,
            canUninstall: probe.installedExists
        )
    }

    private func installedPathIfPresent(_ probe: AgentIntegrationProviderProbe) -> String? {
        guard case .loaded(let installedPath) = probe.manifest, probe.installedExists, let installedPath else {
            return nil
        }
        return installedPath
    }

    /// The card shown before the first authoritative probe lands. Layout-stable
    /// and actionless (`isAuthoritative` false disables install), so cards never
    /// vanish from the pane while probing is in flight. Performs no filesystem
    /// access whatsoever: it is reachable from view body evaluation, so every
    /// path here is pure string composition.
    func placeholderCardState(
        provider: AgentIntegrationInstallProvider,
        setup: AgentIntegrationSetup
    ) -> AgentIntegrationSettingsCardState {
        AgentIntegrationSettingsCardState(
            provider: .init(provider),
            title: provider.displayName,
            subtitle: provider.subtitle,
            binaryPlaceholder: provider.defaultBinaryPath,
            configHomePlaceholder: provider.globalConfigHome(homeDirectory: homeDirectoryURL).path,
            templatePath: installer.templateURL(provider: provider).path,
            renderedPath: installer.renderedFileURL(provider: provider, setup: setup).path,
            globalInstallPath: provider.globalInstallPathPlaceholder(homeDirectory: homeDirectoryURL),
            binaryValidation: .unset(provider.defaultBinaryPath),
            configHomeValidation: .unset(provider.globalConfigHome(homeDirectory: homeDirectoryURL).path),
            status: .checking,
            installedPath: nil,
            isInstalledGlobally: false,
            isProviderEnabled: setup.enabled,
            canUninstall: false,
            isAuthoritative: false
        )
    }

    private static func manifestStatus(
        for observation: AgentIntegrationManifestObservation
    ) -> AgentIntegrationSettingsStatus? {
        switch observation {
        case .missing, .loaded:
            nil
        case .recoverableUnsupportedVersion(let version):
            .installStateRepairRequired(
                String(
                    localized: "Install record format \(version) is newer than this app, but it is empty and can be safely rebuilt",
                    comment: "Recoverable empty agent integration install manifest status"
                )
            )
        case .unsupportedVersion(let version):
            .blocked(
                String(
                    localized: "Install record format \(version) is not supported by this version of awesoMux",
                    comment: "Unsupported agent integration install manifest status"
                )
            )
        case .corrupt:
            .blocked(String(localized: "Install record is corrupt", comment: "Corrupt agent integration install manifest status"))
        case .unreadable:
            .blocked(String(localized: "Install record could not be read", comment: "Unreadable agent integration install manifest status"))
        case .busy:
            .blocked(
                String(
                    localized: "Another awesoMux instance is changing agent integrations; try again",
                    comment: "Agent integration install state lock contention status"
                )
            )
        case .unavailable:
            // Not transient: this catch-all covers permission-denied, disk-full,
            // and read-only-volume, none of which resolve on their own. Say so
            // instead of parking on "temporarily unavailable".
            .blocked(
                String(
                    localized: "Can't read install state. Check permissions and available disk space.",
                    comment: "Unavailable agent integration install state status"
                )
            )
        }
    }

    // MARK: - Mutations (synchronous by design; see issue #415 scope note)

    func install(
        provider: AgentIntegrationInstallProvider,
        setup: AgentIntegrationSetup
    ) throws -> AgentIntegrationSettingsActionResult {
        let installed = try installer.install(
            provider: provider,
            setup: setup,
            homeDirectory: homeDirectoryURL
        )
        return AgentIntegrationSettingsActionResult(
            provider: provider,
            renderedPath: installed.renderedInstall.renderedURL.path,
            installedPath: installed.installedURL.path
        )
    }

    func uninstall(provider: AgentIntegrationInstallProvider) throws -> URL? {
        try installer.uninstall(provider: provider)
    }

    func errorMessage(for error: Error) -> String {
        error.agentIntegrationSettingsMessage
    }

    func normalizedSetup(_ setup: AgentIntegrationSetup) -> AgentIntegrationSetup {
        AgentIntegrationSetup(
            enabled: setup.enabled,
            binaryPath: installer.normalizedOptional(setup.binaryPath),
            configHome: installer.normalizedOptional(setup.configHome)
        )
    }
}

struct AgentIntegrationSettingsCardState: Equatable, Sendable {
    var provider: AgentIntegrationDisplayProvider
    var title: String
    var subtitle: String
    var binaryPlaceholder: String
    var configHomePlaceholder: String
    var templatePath: String
    var renderedPath: String
    var globalInstallPath: String
    var binaryValidation: AgentIntegrationPathValidation
    var configHomeValidation: AgentIntegrationPathValidation
    var status: AgentIntegrationSettingsStatus
    /// The on-disk installed file, when one exists. Tracked separately from
    /// `status` so an "off but installed" card can still surface the path the
    /// status badge no longer names.
    var installedPath: String?
    var isInstalledGlobally: Bool
    var isProviderEnabled: Bool
    var canUninstall: Bool
    /// False only for pre-probe placeholders, where no observation backs the
    /// status yet and install actions must stay disabled.
    var isAuthoritative: Bool = true
    /// True while a scheduled draft validation has not produced a publication
    /// yet; the displayed path validations then describe the previous input.
    var isValidating: Bool = false

    var canInstall: Bool {
        isAuthoritative && isProviderEnabled && status.allowsInstall
    }

    /// "Repair" reinstalls an already-installed global file in place; otherwise
    /// the action is a first install.
    var actionTitle: String {
        if case .installStateRepairRequired = status {
            return String(localized: "Repair state & install", comment: "Agent integration recovery action")
        }
        return isInstalledGlobally ? "Repair globally" : "Install"
    }

    var actionSystemImage: String {
        if case .installStateRepairRequired = status {
            return "arrow.clockwise"
        }
        return isInstalledGlobally ? "arrow.clockwise" : "square.and.arrow.down"
    }
}

enum AgentIntegrationPathValidation: Equatable, Sendable {
    case unset(String)
    case valid(String)
    case invalid(String)

    var displayText: String {
        switch self {
        case .unset(let fallback):
            "Default: \(fallback)"
        case .valid(let path):
            "Valid: \(path)"
        case .invalid(let message):
            message
        }
    }

    var blockingMessage: String? {
        switch self {
        case .unset, .valid:
            nil
        case .invalid(let message):
            message
        }
    }
}

enum AgentIntegrationSettingsStatus: Equatable, Sendable {
    case disabled
    /// No observation has landed yet; nothing about install state is known.
    case checking
    case notInstalled
    case staged
    case installed
    /// On-disk install no longer matches the bundled template (app update or
    /// user edit). Offer Repair globally.
    case updateAvailable
    case installStateRepairRequired(String)
    case blocked(String)
    /// The probe itself did not finish within the watchdog bound, so install
    /// state is unknown rather than negative.
    case timedOut

    var label: String {
        switch self {
        case .disabled:
            "Off"
        case .checking:
            String(localized: "Checking…", comment: "Agent integration card status before the first check lands")
        case .notInstalled:
            "Not installed"
        case .staged:
            "Staged"
        case .installed:
            "Installed"
        case .updateAvailable:
            "Update available"
        case .installStateRepairRequired, .blocked:
            "Needs attention"
        case .timedOut:
            String(localized: "Couldn't check", comment: "Agent integration card status when checking timed out")
        }
    }

    var detail: String {
        switch self {
        case .disabled:
            "Enable this provider to integrate with awesoMux"
        case .checking:
            String(
                localized: "Looking for an installed integration.",
                comment: "Agent integration card status detail while the first check is in flight")
        case .notInstalled:
            "Template has not been installed"
        case .staged:
            "Template is rendered but not installed"
        case .installed:
            "Installed. Restart already-running provider sessions once so they load this file."
        case .updateAvailable:
            "Installed file differs from the current awesoMux template. Repair globally to update, or Remove if you customized it."
        case .installStateRepairRequired(let message):
            message
        case .blocked(let message):
            message
        case .timedOut:
            String(
                localized: "Checking this integration timed out. It will retry when you reopen this pane or edit a field.",
                comment: "Agent integration card status detail after a probe timed out")
        }
    }

    var allowsInstall: Bool {
        switch self {
        case .blocked, .disabled, .checking, .timedOut:
            false
        case .notInstalled, .staged, .installed, .updateAvailable, .installStateRepairRequired:
            true
        }
    }
}

struct AgentIntegrationSettingsActionResult: Equatable, Sendable {
    var provider: AgentIntegrationInstallProvider
    var renderedPath: String
    var installedPath: String
}

extension AgentIntegrationInstallProvider {
    var displayName: String {
        switch self {
        case .openCode:
            "OpenCode"
        case .pi:
            "Pi"
        }
    }

    var subtitle: String {
        switch self {
        case .openCode:
            "Status plugin"
        case .pi:
            "Status extension"
        }
    }

    var defaultBinaryPath: String {
        switch self {
        case .openCode:
            "/opt/homebrew/bin/opencode"
        case .pi:
            "/opt/homebrew/bin/pi"
        }
    }

    func globalInstallPathPlaceholder(homeDirectory: URL) -> String {
        globalExtensionDirectory(configHome: globalConfigHome(homeDirectory: homeDirectory))
            .appending(path: renderedFileName)
            .path
    }
}

extension Error {
    var agentIntegrationSettingsMessage: String {
        guard let error = self as? AgentIntegrationInstallerError else {
            return localizedDescription
        }

        switch error {
        case .providerDisabled:
            return "Enable this provider first"
        case .missingTemplate:
            return "Bundled template is missing"
        case .invalidPath:
            return "Use an absolute path"
        case .executableNotFound:
            return "Executable not found"
        case .executableIsDirectory:
            return "Executable path is a directory"
        case .executableNotExecutable:
            return "Executable is not runnable"
        case .configHomeIsNotDirectory:
            return "Config home is not a directory"
        case .directoryPermissionsUpdateFailed:
            return String(
                localized: "awesoMux couldn’t make its install directory private",
                comment: "Agent integration private directory permission update error"
            )
        case .installManifestUnreadable:
            return String(localized: "Install record could not be read", comment: "Unreadable agent integration install manifest error")
        case .installManifestCorrupt:
            return String(localized: "Install record is corrupt", comment: "Corrupt agent integration install manifest error")
        case .installStateUnavailable:
            return String(
                localized: "Install state is temporarily unavailable", comment: "Unavailable agent integration install state error")
        case .unsupportedManifestVersion:
            return String(
                localized: "Install record format is not supported by this version of awesoMux",
                comment: "Unsupported agent integration install manifest error"
            )
        case .installedFileModified(let url):
            return "Installed file was modified; remove it manually at \(url.path)"
        case .fileRollbackFailed(let url, _, _):
            return "Install state could not be saved and file rollback failed at \(url.path). Repair the file manually before retrying."
        case .installStateBusy:
            return "Another awesoMux instance is changing agent integrations; try again"
        }
    }
}
