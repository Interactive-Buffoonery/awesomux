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

    func cardState(
        provider: AgentIntegrationInstallProvider,
        setup: AgentIntegrationSetup
    ) -> AgentIntegrationSettingsCardState {
        // The manifest is always read, even when the provider is off: an
        // awesoMux file installed before disabling stays on disk, and the card
        // must keep it visible and removable. Reading our own app-support
        // manifest is not provider probing, so the consent gate is intact.
        cardState(
            provider: provider,
            setup: setup,
            manifest: try? installer.loadManifest()
        )
    }

    func cardStates(
        for setups: [AgentIntegrationInstallProvider: AgentIntegrationSetup]
    ) -> [AgentIntegrationInstallProvider: AgentIntegrationSettingsCardState] {
        let manifest = try? installer.loadManifest()
        return setups.reduce(into: [:]) { result, entry in
            result[entry.key] = cardState(provider: entry.key, setup: entry.value, manifest: manifest)
        }
    }

    private func cardState(
        provider: AgentIntegrationInstallProvider,
        setup: AgentIntegrationSetup,
        manifest: AgentIntegrationInstallManifest?
    ) -> AgentIntegrationSettingsCardState {
        let templateURL = installer.templateURL(provider: provider)
        let renderedURL = installer.renderedFileURL(provider: provider, setup: setup)
        let globalInstallURL = try? installer.destinationFileURL(
            provider: provider,
            homeDirectory: homeDirectoryURL,
            configuredConfigHome: setup.configHome
        )

        if !setup.enabled {
            // An awesoMux file installed before the provider was turned off must
            // stay visible and removable. Install stays gated on enablement (the
            // ADR's separate consent step), but uninstall does not require
            // re-enabling just to clean up.
            let installedPath = matchingManifestRecord(provider: provider, manifest: manifest)?.installedPath
            let installedExists = installedPath.map { installer.fileManager.fileExists(atPath: $0) } ?? false
            return AgentIntegrationSettingsCardState(
                provider: .init(provider),
                title: provider.displayName,
                subtitle: provider.subtitle,
                binaryPlaceholder: provider.defaultBinaryPath,
                configHomePlaceholder: provider.globalConfigHome(homeDirectory: homeDirectoryURL).path,
                templatePath: templateURL.path,
                renderedPath: renderedURL.path,
                globalInstallPath: globalInstallURL?.path ?? provider.globalInstallPathPlaceholder(homeDirectory: homeDirectoryURL),
                binaryValidation: .unset(provider.defaultBinaryPath),
                configHomeValidation: .unset(provider.globalConfigHome(homeDirectory: homeDirectoryURL).path),
                status: .disabled,
                installedPath: installedExists ? installedPath : nil,
                isInstalledGlobally: installedExists,
                canInstall: false,
                canUninstall: installedExists
            )
        }

        let binaryValidation = validateExecutable(provider: provider, path: setup.binaryPath)
        let configHomeValidation = validateConfigHome(provider: provider, setup: setup)
        let matchingRecord = matchingManifestRecord(provider: provider, manifest: manifest)
        let installedPath = matchingRecord?.installedPath
        let installedExists = installedPath.map { installer.fileManager.fileExists(atPath: $0) } ?? false
        let renderedExists = installer.fileManager.fileExists(atPath: renderedURL.path)
        let templateExists = installer.fileManager.fileExists(atPath: templateURL.path)

        let status: AgentIntegrationSettingsStatus
        if !templateExists {
            status = .blocked("Bundled template is missing")
        } else if let error = binaryValidation.blockingMessage ?? configHomeValidation.blockingMessage {
            status = .blocked(error)
        } else if installedExists, let installedPath {
            // Byte-compare the live install to the current bundled template so an
            // app update that ships new OpenCode/Pi status code surfaces Repair
            // instead of leaving a silent stale extension in "Installed".
            if installer.installedContentDiffersFromTemplate(
                installedPath: installedPath,
                templateURL: templateURL
            ) {
                status = .updateAvailable
            } else {
                status = .installed
            }
        } else if renderedExists {
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
            templatePath: templateURL.path,
            renderedPath: renderedURL.path,
            globalInstallPath: globalInstallURL?.path ?? provider.globalInstallPathPlaceholder(homeDirectory: homeDirectoryURL),
            binaryValidation: binaryValidation,
            configHomeValidation: configHomeValidation,
            status: status,
            installedPath: installedExists ? installedPath : nil,
            isInstalledGlobally: installedExists,
            canInstall: status.allowsInstall,
            canUninstall: installedExists
        )
    }

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

    private func validateExecutable(
        provider: AgentIntegrationInstallProvider,
        path: String?
    ) -> AgentIntegrationPathValidation {
        do {
            if let url = try installer.validateExecutablePath(path) {
                return .valid(url.path)
            }
            return .unset(provider.defaultBinaryPath)
        } catch {
            return .invalid(error.agentIntegrationSettingsMessage)
        }
    }

    private func validateConfigHome(
        provider: AgentIntegrationInstallProvider,
        setup: AgentIntegrationSetup
    ) -> AgentIntegrationPathValidation {
        do {
            if let url = try installer.validateConfigHomePath(setup.configHome) {
                return .valid(url.path)
            }
            return .unset(provider.globalConfigHome(homeDirectory: homeDirectoryURL).path)
        } catch {
            return .invalid(error.agentIntegrationSettingsMessage)
        }
    }

    private func matchingManifestRecord(
        provider: AgentIntegrationInstallProvider,
        manifest: AgentIntegrationInstallManifest?
    ) -> AgentIntegrationInstallRecord? {
        guard let manifest else {
            return nil
        }
        // Installs are one-per-provider, so the provider alone identifies the
        // record. Matching on provider (not the live binary/config-home fields)
        // keeps the card on "Installed" while the user edits the config home
        // before reinstalling, instead of transiently flipping to "Not installed".
        return manifest.records.first { $0.provider == provider }
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
    var canInstall: Bool
    var canUninstall: Bool

    /// "Repair" reinstalls an already-installed global file in place; otherwise
    /// the action is a first install.
    var actionTitle: String {
        isInstalledGlobally ? "Repair globally" : "Install"
    }

    var actionSystemImage: String {
        isInstalledGlobally ? "arrow.clockwise" : "square.and.arrow.down"
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
    case notInstalled
    case staged
    case installed
    /// On-disk install no longer matches the bundled template (app update or
    /// user edit). Offer Repair globally.
    case updateAvailable
    case blocked(String)

    var label: String {
        switch self {
        case .disabled:
            "Off"
        case .notInstalled:
            "Not installed"
        case .staged:
            "Staged"
        case .installed:
            "Installed"
        case .updateAvailable:
            "Update available"
        case .blocked:
            "Needs attention"
        }
    }

    var detail: String {
        switch self {
        case .disabled:
            "Enable this provider to integrate with awesoMux"
        case .notInstalled:
            "Template has not been installed"
        case .staged:
            "Template is rendered but not installed"
        case .installed:
            "Installed. Restart already-running provider sessions once so they load this file."
        case .updateAvailable:
            "Installed file differs from the current awesoMux template. Repair globally to update, or Remove if you customized it."
        case .blocked(let message):
            message
        }
    }

    var allowsInstall: Bool {
        switch self {
        case .blocked, .disabled:
            false
        case .notInstalled, .staged, .installed, .updateAvailable:
            true
        }
    }
}

struct AgentIntegrationSettingsActionResult: Equatable, Sendable {
    var provider: AgentIntegrationInstallProvider
    var renderedPath: String
    var installedPath: String
}

private extension AgentIntegrationInstallProvider {
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

private extension Error {
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
        case .unsupportedManifestVersion:
            return "Install manifest is newer than this app"
        case .installedFileModified(let url):
            return "Installed file was modified; remove it manually at \(url.path)"
        case .installStateBusy:
            return "Another awesoMux instance is changing agent integrations; try again"
        }
    }
}
