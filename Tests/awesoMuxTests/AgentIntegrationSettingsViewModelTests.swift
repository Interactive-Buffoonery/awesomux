import AwesoMuxConfig
import Foundation
import Testing
@testable import awesoMux

@Suite("Agent integration settings view model")
struct AgentIntegrationSettingsViewModelTests {
    @Test("default card state is disabled and does not allow install")
    func defaultCardStateIsDisabledAndDoesNotAllowInstall() throws {
        try Self.withTemporaryDirectory { directory in
            let viewModel = Self.viewModel(in: directory)
            let home = directory.appending(path: "home", directoryHint: .isDirectory)

            let state = try Self.cardState(viewModel, provider: .openCode, setup: .defaultValue)

            #expect(state.title == "OpenCode")
            #expect(state.status == .disabled)
            #expect(!state.canInstall)
            #expect(!state.canUninstall)
            #expect(state.binaryValidation == .unset("/opt/homebrew/bin/opencode"))
            let defaultConfigHome =
                home
                .appending(path: ".config", directoryHint: .isDirectory)
                .appending(path: "opencode", directoryHint: .isDirectory)
            #expect(state.configHomeValidation == .unset(defaultConfigHome.path))
            #expect(state.templatePath.hasSuffix("awesomux-opencode-status.js.template"))
            #expect(state.renderedPath.contains("/AgentIntegrations/rendered/open_code/"))
            #expect(state.globalInstallPath.hasSuffix(".config/opencode/plugins/awesomux-opencode-status.js"))
            #expect(!state.isInstalledGlobally)
        }
    }

    @Test("invalid configured paths block install")
    func invalidConfiguredPathsBlockInstall() throws {
        try Self.withTemporaryDirectory { directory in
            let viewModel = Self.viewModel(in: directory)
            let setup = AgentIntegrationSetup(
                enabled: true,
                binaryPath: "relative/pi",
                configHome: "relative/config"
            )

            let state = try Self.cardState(viewModel, provider: .pi, setup: setup)

            #expect(state.binaryValidation == .invalid("Use an absolute path"))
            #expect(state.configHomeValidation == .invalid("Use an absolute path"))
            #expect(state.status == .blocked("Use an absolute path"))
            #expect(!state.canInstall)
        }
    }

    @Test("disabled configured paths do not probe or block")
    func disabledConfiguredPathsDoNotProbeOrBlock() throws {
        try Self.withTemporaryDirectory { directory in
            let viewModel = Self.viewModel(in: directory)
            let setup = AgentIntegrationSetup(
                enabled: false,
                binaryPath: "relative/pi",
                configHome: "relative/config"
            )

            let state = try Self.cardState(viewModel, provider: .pi, setup: setup)

            #expect(state.status == .disabled)
            #expect(state.binaryValidation == .unset("/opt/homebrew/bin/pi"))
            let defaultConfigHome =
                directory
                .appending(path: "home", directoryHint: .isDirectory)
                .appending(path: ".pi", directoryHint: .isDirectory)
                .appending(path: "agent", directoryHint: .isDirectory)
            #expect(state.configHomeValidation == .unset(defaultConfigHome.path))
            #expect(!state.canInstall)
            #expect(!state.canUninstall)
        }
    }

    @Test("rendered template reports staged status")
    func renderedTemplateReportsStagedStatus() throws {
        try Self.withTemporaryDirectory { directory in
            let installer = Self.installer(in: directory)
            let viewModel = Self.viewModel(in: directory, installer: installer)
            let setup = AgentIntegrationSetup(enabled: true)

            _ = try installer.render(provider: .pi, setup: setup)

            let state = try Self.cardState(viewModel, provider: .pi, setup: setup)

            #expect(state.status == .staged)
            #expect(!state.isInstalledGlobally)
            #expect(state.actionTitle == "Install")
            #expect(state.canInstall)
        }
    }

    @Test("an empty future manifest offers explicit repair")
    func emptyFutureManifestOffersExplicitRepair() throws {
        try Self.withTemporaryDirectory { directory in
            let installer = Self.installer(in: directory)
            let viewModel = Self.viewModel(in: directory, installer: installer)
            try FileManager.default.createDirectory(
                at: installer.manifestURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let unsupportedVersion = AgentIntegrationInstallManifest.currentVersion + 1
            try Data(#"{"records":[],"version":\#(unsupportedVersion)}"#.utf8)
                .write(to: installer.manifestURL)

            let states = viewModel.cardStates(for: [.pi: .init(enabled: true)])
            let state = try #require(states[.pi])

            #expect(
                state.status
                    == .installStateRepairRequired(
                        "Install record format \(unsupportedVersion) is newer than this app, but it is empty and can be safely rebuilt"))
            #expect(state.canInstall)
            #expect(state.actionTitle == "Repair state & install")

            let disabledState = try Self.cardState(
                viewModel,
                provider: .pi,
                setup: .init(enabled: false)
            )
            #expect(
                disabledState.status
                    == .installStateRepairRequired(
                        "Install record format \(unsupportedVersion) is newer than this app, but it is empty and can be safely rebuilt"))
            #expect(!disabledState.canInstall)

            let invalidState = try Self.cardState(
                viewModel,
                provider: .pi,
                setup: .init(enabled: true, binaryPath: "relative/pi")
            )
            #expect(invalidState.status == .blocked("Use an absolute path"))
            #expect(!invalidState.canInstall)
        }
    }

    @Test("install writes global file and reports installed status")
    func installWritesGlobalFileAndReportsInstalledStatus() throws {
        try Self.withTemporaryDirectory { directory in
            let viewModel = Self.viewModel(in: directory)
            let configHome =
                directory
                .appending(path: "home", directoryHint: .isDirectory)
                .appending(path: ".config", directoryHint: .isDirectory)
                .appending(path: "opencode", directoryHint: .isDirectory)
            let setup = AgentIntegrationSetup(enabled: true, configHome: configHome.path)

            let result = try viewModel.install(provider: .openCode, setup: setup)
            let state = try Self.cardState(viewModel, provider: .openCode, setup: setup)

            #expect(FileManager.default.fileExists(atPath: result.installedPath))
            #expect(result.installedPath.hasSuffix(".config/opencode/plugins/awesomux-opencode-status.js"))
            #expect(state.status == .installed)
            #expect(state.status.detail.contains("Restart already-running provider sessions"))
            #expect(state.isInstalledGlobally)
            // An already-installed global file reinstalls in place as a repair.
            #expect(state.actionTitle == "Repair globally")
            #expect(state.canUninstall)
        }
    }

    @Test("installed file that diverges from the current template reports update available")
    func installedFileDivergingFromTemplateReportsUpdateAvailable() throws {
        try Self.withTemporaryDirectory { directory in
            let viewModel = Self.viewModel(in: directory)
            let configHome =
                directory
                .appending(path: "home", directoryHint: .isDirectory)
                .appending(path: ".config", directoryHint: .isDirectory)
                .appending(path: "opencode", directoryHint: .isDirectory)
            let setup = AgentIntegrationSetup(enabled: true, configHome: configHome.path)

            let result = try viewModel.install(provider: .openCode, setup: setup)
            try "stale-extension-body\n".write(
                to: URL(fileURLWithPath: result.installedPath),
                atomically: true,
                encoding: .utf8
            )

            let state = try Self.cardState(viewModel, provider: .openCode, setup: setup)
            #expect(state.status == .updateAvailable)
            #expect(state.canInstall)
            #expect(state.actionTitle == "Repair globally")
            #expect(state.status.detail.contains("Repair globally"))
        }
    }

    @Test("installed file stays visible and removable after the provider is disabled")
    func installedFileStaysRemovableAfterDisabling() throws {
        try Self.withTemporaryDirectory { directory in
            let viewModel = Self.viewModel(in: directory)
            let configHome =
                directory
                .appending(path: "home", directoryHint: .isDirectory)
                .appending(path: ".config", directoryHint: .isDirectory)
                .appending(path: "opencode", directoryHint: .isDirectory)
            let enabledSetup = AgentIntegrationSetup(enabled: true, configHome: configHome.path)

            let result = try viewModel.install(provider: .openCode, setup: enabledSetup)

            // Turning the provider off must not hide or strand the installed
            // file: an explicit-consent integration leaves cleanup reachable
            // without forcing a re-enable.
            let disabledSetup = AgentIntegrationSetup(enabled: false, configHome: configHome.path)
            let state = try Self.cardState(viewModel, provider: .openCode, setup: disabledSetup)

            #expect(state.status == .disabled)
            #expect(state.isInstalledGlobally)
            #expect(state.canUninstall)
            #expect(!state.canInstall)
            #expect(state.installedPath == result.installedPath)
        }
    }

    @Test("missing bundled template blocks install")
    func missingBundledTemplateBlocksInstall() throws {
        try Self.withTemporaryDirectory { directory in
            let resources = directory.appending(path: "resources", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            let installer = AgentIntegrationInstaller(
                resourcesDirectoryURL: resources,
                supportDirectoryURL: directory.appending(path: "support", directoryHint: .isDirectory)
            )
            let viewModel = Self.viewModel(in: directory, installer: installer)

            let state = try Self.cardState(
                viewModel,
                provider: .openCode,
                setup: AgentIntegrationSetup(enabled: true)
            )

            #expect(state.status == .blocked("Bundled template is missing"))
            #expect(!state.canInstall)
        }
    }

    @Test("pre-opt-in card exposes preview paths and locks all install controls")
    func preOptInCardExposesPreviewPathsAndLocksControls() throws {
        try Self.withTemporaryDirectory { directory in
            let viewModel = Self.viewModel(in: directory)

            let state = try Self.cardState(viewModel, provider: .openCode, setup: .defaultValue)

            // Before opt-in every path the enabled card would show is already
            // populated as a preview, so the user can see what they are consenting
            // to. None of the install controls are live.
            #expect(!state.binaryPlaceholder.isEmpty)
            #expect(!state.configHomePlaceholder.isEmpty)
            #expect(state.templatePath.hasSuffix("awesomux-opencode-status.js.template"))
            #expect(state.renderedPath.contains("/AgentIntegrations/rendered/open_code/"))
            #expect(state.globalInstallPath.hasSuffix(".config/opencode/plugins/awesomux-opencode-status.js"))
            #expect(state.binaryValidation == .unset(state.binaryPlaceholder))
            #expect(state.configHomeValidation == .unset(state.configHomePlaceholder))
            #expect(!state.isInstalledGlobally)
            #expect(!state.canInstall)
            #expect(!state.canUninstall)
        }
    }

    @Test("display providers route to exactly one install machinery")
    func displayProvidersRouteToOneMachinery() throws {
        // File-drop providers route to the installer; CLI-driven providers route
        // to the plugin runner. Each case carries exactly one of the two seams.
        #expect(AgentIntegrationDisplayProvider.openCode.installable == .openCode)
        #expect(AgentIntegrationDisplayProvider.openCode.pluginProvider == nil)
        #expect(AgentIntegrationDisplayProvider.pi.installable == .pi)
        #expect(AgentIntegrationDisplayProvider.pi.pluginProvider == nil)
        #expect(AgentIntegrationDisplayProvider.grok.installable == nil)
        #expect(AgentIntegrationDisplayProvider.grok.pluginProvider == .grok)

        #expect(AgentIntegrationDisplayProvider.claudeCode.installable == nil)
        #expect(AgentIntegrationDisplayProvider.claudeCode.pluginProvider == .claudeCode)
        #expect(AgentIntegrationDisplayProvider.codex.installable == nil)
        #expect(AgentIntegrationDisplayProvider.codex.pluginProvider == .codex)
    }

    @Test("error message maps installer errors and falls back for others")
    func errorMessageMapsInstallerErrorsAndFallsBackForOthers() throws {
        try Self.withTemporaryDirectory { directory in
            let viewModel = Self.viewModel(in: directory)

            let installerError = AgentIntegrationInstallerError.invalidPath("relative/pi")
            #expect(viewModel.errorMessage(for: installerError) == "Use an absolute path")
            let disabledError = AgentIntegrationInstallerError.providerDisabled(.openCode)
            #expect(viewModel.errorMessage(for: disabledError) == "Enable this provider first")
            let rollbackURL = directory.appending(path: "awesomux-pi-status.ts")
            let rollbackError = AgentIntegrationInstallerError.fileRollbackFailed(
                rollbackURL,
                operationError: "manifest write failed",
                rollbackError: "file restore failed"
            )
            #expect(viewModel.errorMessage(for: rollbackError).contains(rollbackURL.path))
            #expect(viewModel.errorMessage(for: rollbackError).contains("rollback failed"))

            let plainError = NSError(
                domain: "test",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "boom"]
            )
            #expect(viewModel.errorMessage(for: plainError) == "boom")
        }
    }

    private static func viewModel(
        in directory: URL,
        installer: AgentIntegrationInstaller? = nil
    ) -> AgentIntegrationSettingsViewModel {
        AgentIntegrationSettingsViewModel(
            installer: installer ?? Self.installer(in: directory),
            homeDirectoryURL: directory.appending(path: "home", directoryHint: .isDirectory)
        )
    }

    private static func installer(in directory: URL) -> AgentIntegrationInstaller {
        AgentIntegrationInstaller(
            resourcesDirectoryURL: Self.packageResourcesURL,
            supportDirectoryURL: directory.appending(path: "support", directoryHint: .isDirectory)
        )
    }

    private static func cardState(
        _ viewModel: AgentIntegrationSettingsViewModel,
        provider: AgentIntegrationInstallProvider,
        setup: AgentIntegrationSetup
    ) throws -> AgentIntegrationSettingsCardState {
        try #require(viewModel.cardStates(for: [provider: setup])[provider])
    }

    private static func withTemporaryDirectory(_ operation: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "awesomux-agent-integration-settings-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try operation(directory)
    }

    private static var packageResourcesURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Resources", directoryHint: .isDirectory)
    }
}
