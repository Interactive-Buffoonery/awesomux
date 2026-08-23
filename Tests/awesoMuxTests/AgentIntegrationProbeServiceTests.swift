import AwesoMuxConfig
import Foundation
import Testing
@testable import awesoMux

@Suite("Agent integration probe service")
struct AgentIntegrationProbeServiceTests {
    @Test("default setup observes missing manifest and unset validations")
    func defaultSetupObservesMissingManifest() async throws {
        try await Self.withService { directory, _, _, service in
            let probe = await service.probe(provider: .openCode, setup: .defaultValue)

            // Disabled cards skip existence stats entirely and show previews.
            #expect(probe.manifest == .missing)
            #expect(!probe.installedExists)
            #expect(!probe.renderedExists)
            #expect(!probe.templateExists)
            #expect(probe.binaryValidation == .unset("/opt/homebrew/bin/opencode"))

            let enabled = await service.probe(
                provider: .openCode,
                setup: AgentIntegrationSetup(enabled: true)
            )
            #expect(enabled.templateExists)

            let defaultConfigHome =
                directory
                .appending(path: "home", directoryHint: .isDirectory)
                .appending(path: ".config", directoryHint: .isDirectory)
                .appending(path: "opencode", directoryHint: .isDirectory)
            #expect(enabled.configHomeValidation == .unset(defaultConfigHome.path))
        }
    }

    @Test("disabled setup skips configured-path stats")
    func disabledSetupSkipsConfiguredPathStats() async throws {
        try await Self.withService { _, home, support, service in
            let setup = AgentIntegrationSetup(enabled: false, binaryPath: "relative/pi")
            let probe = await service.probe(provider: .pi, setup: setup)

            // An invalid path would surface as .invalid for an enabled setup;
            // disabled cards show unset previews regardless of disk state.
            #expect(probe.binaryValidation == .unset("/opt/homebrew/bin/pi"))
        }
    }

    @Test("rendered-but-uninstalled template observes staged shape")
    func renderedTemplateObservesStagedShape() async throws {
        try await Self.withService { _, home, support, service in
            let installer = Self.installer(resources: Self.packageResourcesURL, support: support)
            let setup = AgentIntegrationSetup(enabled: true)
            _ = try installer.render(provider: .pi, setup: setup)

            let probe = await service.probe(provider: .pi, setup: setup)

            #expect(probe.manifest == .missing)
            #expect(probe.templateExists)
            #expect(probe.renderedExists)
            #expect(!probe.installedExists)
            #expect(probe.installedContentDiffersFromTemplate == false)
        }
    }

    @Test("empty future manifest surfaces as recoverable observation")
    func emptyFutureManifestSurfacesRecoverable() async throws {
        try await Self.withService { _, home, support, service in
            let installer = Self.installer(resources: Self.packageResourcesURL, support: support)
            try FileManager.default.createDirectory(
                at: installer.manifestURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let unsupportedVersion = AgentIntegrationInstallManifest.currentVersion + 1
            try Data(#"{"records":[],"version":\#(unsupportedVersion)}"#.utf8)
                .write(to: installer.manifestURL)

            let probe = await service.probe(provider: .openCode, setup: .init(enabled: true))

            // An empty unsupported-version record set is safe to rebuild, so
            // the observation carries the recoverable case.
            #expect(probe.manifest == .recoverableUnsupportedVersion(unsupportedVersion))
        }
    }

    @Test("corrupt manifest surfaces as corrupt observation")
    func corruptManifestSurfaces() async throws {
        try await Self.withService { _, home, support, service in
            let installer = Self.installer(resources: Self.packageResourcesURL, support: support)
            try FileManager.default.createDirectory(
                at: installer.manifestURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("not json".utf8).write(to: installer.manifestURL)

            let probe = await service.probe(provider: .pi, setup: .init(enabled: true))

            #expect(probe.manifest == .corrupt)
        }
    }

    @Test("installed file diverging from template reports content drift")
    func installedDriftObserved() async throws {
        try await Self.withService { _, home, support, service in
            let installer = Self.installer(resources: Self.packageResourcesURL, support: support)
            let configHome =
                home
                .appending(path: ".config", directoryHint: .isDirectory)
                .appending(path: "opencode", directoryHint: .isDirectory)
            let setup = AgentIntegrationSetup(enabled: true, configHome: configHome.path)

            let installed = try installer.install(provider: .openCode, setup: setup, homeDirectory: home)
            try "drifted-body\n".write(
                to: URL(fileURLWithPath: installed.installedURL.path),
                atomically: true,
                encoding: .utf8
            )

            let probe = await service.probe(provider: .openCode, setup: setup)

            guard case .loaded(let installedPath) = probe.manifest else {
                Issue.record("expected a loaded manifest, got \(probe.manifest)")
                return
            }
            #expect(installedPath == installed.installedURL.path)
            #expect(probe.installedExists)
            #expect(probe.installedContentDiffersFromTemplate)
        }
    }

    // MARK: - Helpers

    /// One isolated fixture per invocation: concurrent tests must never share a
    /// support directory, or their manifests and rendered trees trample each
    /// other.
    private static func withService(
        _ operation: (URL, URL, URL, AgentIntegrationProbeService) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "awesomux-probe-service-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let home = directory.appending(path: "home", directoryHint: .isDirectory)
        let support = directory.appending(path: "support", directoryHint: .isDirectory)
        let service = AgentIntegrationProbeService(
            homeDirectoryURL: home,
            resourcesDirectoryURL: packageResourcesURL,
            supportDirectoryURL: support
        )
        try await operation(directory, home, support, service)
    }

    private static func installer(resources: URL, support: URL) -> AgentIntegrationInstaller {
        AgentIntegrationInstaller(
            resourcesDirectoryURL: resources,
            supportDirectoryURL: support
        )
    }

    private static var packageResourcesURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Resources", directoryHint: .isDirectory)
    }
}
