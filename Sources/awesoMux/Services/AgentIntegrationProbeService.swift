import AwesoMuxConfig
import Foundation

/// What a probe observed about the install manifest for one provider. A value
/// snapshot of `AgentInstallManifestLoadState` so observations can cross actor
/// boundaries without carrying the manifest store or its writer closure.
enum AgentIntegrationManifestObservation: Sendable, Equatable {
    case missing
    case loaded(installedPath: String?)
    case recoverableUnsupportedVersion(Int)
    case unsupportedVersion(Int)
    case corrupt
    case unreadable
    case busy
    case unavailable
}

/// Everything one probe run learned from disk about one provider's integration
/// setup. Deriving an `AgentIntegrationSettingsCardState` from this snapshot is
/// pure; all file access happens inside the probing service.
struct AgentIntegrationProviderProbe: Sendable, Equatable {
    var manifest: AgentIntegrationManifestObservation
    var installedExists: Bool
    var templatePath: String
    var renderedPath: String
    var globalInstallPath: String
    var binaryValidation: AgentIntegrationPathValidation
    var configHomeValidation: AgentIntegrationPathValidation
    var templateExists: Bool
    var renderedExists: Bool
    var installedContentDiffersFromTemplate: Bool
}

protocol AgentIntegrationProbing: Sendable {
    func probe(provider: AgentIntegrationInstallProvider, setup: AgentIntegrationSetup) async
        -> AgentIntegrationProviderProbe
}

/// Confines every settings-time read of installer state (manifest load, stats,
/// template byte-compare) to a single actor so no caller can reintroduce disk
/// I/O on the main thread. The installer is constructed inside the actor: it is
/// deliberately not Sendable (its `manifestWriter` closure), and this keeps it
/// from ever crossing an isolation boundary.
actor AgentIntegrationProbeService: AgentIntegrationProbing {
    /// Directory overrides exist so tests can point the confined installer at
    /// temporary locations; everything passed in is a Sendable value and the
    /// installer itself is constructed inside the actor.
    private let resourcesDirectoryURL: URL?
    private let supportDirectoryURL: URL?
    private let homeDirectoryURL: URL

    init(
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        resourcesDirectoryURL: URL? = nil,
        supportDirectoryURL: URL? = nil
    ) {
        self.resourcesDirectoryURL = resourcesDirectoryURL
        self.supportDirectoryURL = supportDirectoryURL
        self.homeDirectoryURL = homeDirectoryURL
    }

    func probe(
        provider: AgentIntegrationInstallProvider,
        setup: AgentIntegrationSetup
    ) -> AgentIntegrationProviderProbe {
        let installer = makeInstaller()

        let manifestObservation: AgentIntegrationManifestObservation
        switch installer.loadManifestState() {
        case .missing:
            manifestObservation = .missing
        case .loaded(let manifest):
            let installedPath = manifest.records.first { $0.provider == provider }?.installedPath
            manifestObservation = .loaded(installedPath: installedPath)
        case .failed(.recoverableUnsupportedVersion(let version)):
            manifestObservation = .recoverableUnsupportedVersion(version)
        case .failed(.unsupportedVersion(let version)):
            manifestObservation = .unsupportedVersion(version)
        case .failed(.corrupt):
            manifestObservation = .corrupt
        case .failed(.unreadable):
            manifestObservation = .unreadable
        case .failed(.busy):
            manifestObservation = .busy
        case .failed(.unavailable):
            manifestObservation = .unavailable
        }

        let templateURL = installer.templateURL(provider: provider)
        let renderedURL = installer.renderedFileURL(provider: provider, setup: setup)
        let globalInstallURL = try? installer.destinationFileURL(
            provider: provider,
            homeDirectory: homeDirectoryURL,
            configuredConfigHome: setup.configHome
        )

        // Disabled providers never stat their configured paths; the card shows
        // the defaults as unset previews regardless of what is on disk.
        let binaryValidation: AgentIntegrationPathValidation
        let configHomeValidation: AgentIntegrationPathValidation
        if setup.enabled {
            binaryValidation = Self.validateExecutable(
                installer: installer,
                provider: provider,
                path: setup.binaryPath
            )
            configHomeValidation = Self.validateConfigHome(
                installer: installer,
                provider: provider,
                path: setup.configHome,
                homeDirectoryURL: homeDirectoryURL
            )
        } else {
            binaryValidation = .unset(provider.defaultBinaryPath)
            configHomeValidation = .unset(provider.globalConfigHome(homeDirectory: homeDirectoryURL).path)
        }

        let recordedInstalledPath: String?
        if case .loaded(let path) = manifestObservation {
            recordedInstalledPath = path
        } else {
            recordedInstalledPath = nil
        }
        let installedExists = recordedInstalledPath.map { installer.fileManager.fileExists(atPath: $0) } ?? false

        if setup.enabled {
            let templateExists = installer.fileManager.fileExists(atPath: templateURL.path)
            let renderedExists = installer.fileManager.fileExists(atPath: renderedURL.path)
            let contentDiffers =
                templateExists && installedExists && recordedInstalledPath != nil
                ? installer.installedContentDiffersFromTemplate(
                    installedPath: recordedInstalledPath ?? "",
                    templateURL: templateURL
                )
                : false
            return AgentIntegrationProviderProbe(
                manifest: manifestObservation,
                installedExists: installedExists,
                templatePath: templateURL.path,
                renderedPath: renderedURL.path,
                globalInstallPath: globalInstallURL?.path ?? provider.globalInstallPathPlaceholder(homeDirectory: homeDirectoryURL),
                binaryValidation: binaryValidation,
                configHomeValidation: configHomeValidation,
                templateExists: templateExists,
                renderedExists: renderedExists,
                installedContentDiffersFromTemplate: contentDiffers
            )
        }

        return AgentIntegrationProviderProbe(
            manifest: manifestObservation,
            installedExists: installedExists,
            templatePath: templateURL.path,
            renderedPath: renderedURL.path,
            globalInstallPath: globalInstallURL?.path ?? provider.globalInstallPathPlaceholder(homeDirectory: homeDirectoryURL),
            binaryValidation: binaryValidation,
            configHomeValidation: configHomeValidation,
            templateExists: false,
            renderedExists: false,
            installedContentDiffersFromTemplate: false
        )
    }

    private func makeInstaller() -> AgentIntegrationInstaller {
        if let resourcesDirectoryURL {
            return AgentIntegrationInstaller(
                resourcesDirectoryURL: resourcesDirectoryURL,
                supportDirectoryURL: supportDirectoryURL
            )
        }
        return AgentIntegrationInstaller()
    }

    private static func validateExecutable(
        installer: AgentIntegrationInstaller,
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

    private static func validateConfigHome(
        installer: AgentIntegrationInstaller,
        provider: AgentIntegrationInstallProvider,
        path: String?,
        homeDirectoryURL: URL
    ) -> AgentIntegrationPathValidation {
        do {
            if let url = try installer.validateConfigHomePath(path) {
                return .valid(url.path)
            }
            return .unset(provider.globalConfigHome(homeDirectory: homeDirectoryURL).path)
        } catch {
            return .invalid(error.agentIntegrationSettingsMessage)
        }
    }
}
