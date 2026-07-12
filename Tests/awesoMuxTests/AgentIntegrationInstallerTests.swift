import AwesoMuxConfig
import Foundation
import Testing
@testable import awesoMux

@Suite("Agent integration installer")
struct AgentIntegrationInstallerTests {
    @Test("settings installer stays limited to provider-owned file templates")
    func settingsInstallerExcludesNativeMarketplaceProviders() {
        // Claude Code, Codex, and Grok ship as native plugin marketplace trees. They
        // must not be swept into this provider-owned file installer without a
        // separate settings opt-in design.
        #expect(AgentIntegrationInstallProvider.allCases == [.openCode, .pi])
    }

    @Test("renders file-drop templates without changing global install state")
    func rendersTemplatesWithoutChangingManifest() throws {
        try Self.withTemporaryDirectory { supportDirectory in
            let installer = AgentIntegrationInstaller(
                resourcesDirectoryURL: Self.packageResourcesURL,
                supportDirectoryURL: supportDirectory
            )

            let openCode = try installer.render(
                provider: .openCode,
                setup: AgentIntegrationSetup(
                    enabled: true,
                    binaryPath: "/opt/homebrew/bin/opencode",
                    configHome: "/Users/example/.config/opencode"
                )
            )
            let pi = try installer.render(
                provider: .pi,
                setup: AgentIntegrationSetup(
                    enabled: true,
                    binaryPath: "/opt/homebrew/bin/pi",
                    configHome: "/Users/example/.pi/agent"
                )
            )
            #expect(openCode.renderedURL.lastPathComponent == "awesomux-opencode-status.js")
            #expect(pi.renderedURL.lastPathComponent == "awesomux-pi-status.ts")
            #expect(FileManager.default.fileExists(atPath: openCode.renderedURL.path))
            #expect(FileManager.default.fileExists(atPath: pi.renderedURL.path))

            #expect(try installer.loadManifest() == .empty)
            #expect(!FileManager.default.fileExists(atPath: installer.manifestURL.path))
        }
    }

    @Test("re-render leaves an installed record pointing at its installed source")
    func rerenderLeavesInstalledRecordUnchanged() throws {
        try Self.withTemporaryDirectory { supportDirectory in
            let installer = AgentIntegrationInstaller(
                resourcesDirectoryURL: Self.packageResourcesURL,
                supportDirectoryURL: supportDirectory
            )
            let configHome = supportDirectory.appending(path: "opencode", directoryHint: .isDirectory)
            let setup = AgentIntegrationSetup(
                enabled: true,
                configHome: configHome.path
            )

            let home = supportDirectory.appending(path: "home", directoryHint: .isDirectory)
            _ = try installer.install(provider: .openCode, setup: setup, homeDirectory: home)
            let recordBefore = try #require(try installer.loadManifest().records.first)
            _ = try installer.render(
                provider: .openCode,
                setup: AgentIntegrationSetup(
                    enabled: true,
                    configHome: supportDirectory.appending(path: "other-opencode").path
                )
            )

            #expect(try installer.loadManifest().records == [recordBefore])
        }
    }

    @Test("separate profiles share one canonical install manifest")
    func profilesShareCanonicalManifest() throws {
        try Self.withTemporaryDirectory { directory in
            let installState = directory.appending(path: "global", directoryHint: .isDirectory)
            let production = AgentIntegrationInstaller(
                resourcesDirectoryURL: Self.packageResourcesURL,
                supportDirectoryURL: directory.appending(path: "production", directoryHint: .isDirectory),
                installStateDirectoryURL: installState
            )
            let development = AgentIntegrationInstaller(
                resourcesDirectoryURL: Self.packageResourcesURL,
                supportDirectoryURL: directory.appending(path: "development", directoryHint: .isDirectory),
                installStateDirectoryURL: installState
            )
            let home = directory.appending(path: "home", directoryHint: .isDirectory)

            let installed = try development.install(
                provider: .pi,
                setup: AgentIntegrationSetup(enabled: true),
                homeDirectory: home
            )

            #expect(production.manifestURL == development.manifestURL)
            #expect(production.renderedFileURL(provider: .pi, setup: .init(enabled: true))
                != development.renderedFileURL(provider: .pi, setup: .init(enabled: true)))
            #expect(try production.loadManifest().records.first?.installedPath == installed.installedURL.path)
            #expect(try production.uninstall(provider: .pi) == installed.installedURL)
        }
    }

    @Test("legacy development manifest imports only when canonical state is absent")
    func importsLegacyManifestWithoutOverwritingCanonicalState() throws {
        try Self.withTemporaryDirectory { directory in
            let canonical = directory.appending(path: "canonical", directoryHint: .isDirectory)
            let legacy = directory.appending(path: "legacy", directoryHint: .isDirectory)
            let installer = AgentIntegrationInstaller(
                resourcesDirectoryURL: Self.packageResourcesURL,
                supportDirectoryURL: directory.appending(path: "rendered", directoryHint: .isDirectory),
                installStateDirectoryURL: canonical,
                legacyInstallStateDirectoryURL: legacy
            )
            try Self.writeManifest(
                .init(version: 1, records: [Self.record(provider: .pi, installedPath: "/tmp/legacy")]),
                to: legacy.appending(path: "install-manifest.json")
            )

            #expect(try installer.loadManifest().records.first?.installedPath == "/tmp/legacy")

            try Self.writeManifest(
                .init(version: 1, records: [Self.record(provider: .pi, installedPath: "/tmp/canonical")]),
                to: installer.manifestURL
            )
            try Self.writeManifest(
                .init(version: 1, records: [Self.record(provider: .pi, installedPath: "/tmp/new-legacy")]),
                to: legacy.appending(path: "install-manifest.json")
            )

            #expect(try installer.loadManifest().records.first?.installedPath == "/tmp/canonical")
        }
    }

    @Test("invalid legacy state does not poison canonical installs")
    func invalidLegacyManifestIsIgnored() throws {
        try Self.withTemporaryDirectory { directory in
            let canonical = directory.appending(path: "canonical", directoryHint: .isDirectory)
            let legacy = directory.appending(path: "legacy", directoryHint: .isDirectory)
            let installer = AgentIntegrationInstaller(
                resourcesDirectoryURL: Self.packageResourcesURL,
                supportDirectoryURL: directory.appending(path: "rendered", directoryHint: .isDirectory),
                installStateDirectoryURL: canonical,
                legacyInstallStateDirectoryURL: legacy
            )
            let legacyManifestURL = legacy.appending(path: "install-manifest.json")
            try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
            try Data(#"{"version":999,"records":[]}"#.utf8).write(to: legacyManifestURL)

            #expect(try installer.loadManifest() == .empty)
            #expect(!FileManager.default.fileExists(atPath: installer.manifestURL.path))

            let installed = try installer.install(
                provider: .openCode,
                setup: .init(enabled: true),
                homeDirectory: directory.appending(path: "home", directoryHint: .isDirectory)
            )
            #expect(FileManager.default.fileExists(atPath: installed.installedURL.path))
            #expect(try installer.loadManifest().records.count == 1)
        }
    }

    @Test("a concurrent global mutation fails without changing files")
    func globalMutationLockFailsClosed() throws {
        try Self.withTemporaryDirectory { directory in
            let installState = directory.appending(path: "global", directoryHint: .isDirectory)
            let installer = AgentIntegrationInstaller(
                resourcesDirectoryURL: Self.packageResourcesURL,
                supportDirectoryURL: directory.appending(path: "rendered", directoryHint: .isDirectory),
                installStateDirectoryURL: installState
            )
            let lockHolder = try Self.startExternalLockHolder(in: installState)
            defer {
                lockHolder.terminate()
                lockHolder.waitUntilExit()
            }
            let home = directory.appending(path: "home", directoryHint: .isDirectory)

            #expect(throws: AgentIntegrationInstallerError.installStateBusy) {
                try installer.install(
                    provider: .openCode,
                    setup: AgentIntegrationSetup(enabled: true),
                    homeDirectory: home
                )
            }
            #expect(!FileManager.default.fileExists(atPath: installer.manifestURL.path))
            #expect(!FileManager.default.fileExists(atPath: try installer.destinationFileURL(
                provider: .openCode,
                homeDirectory: home
            ).path))
        }
    }

    @Test("install writes templates to provider destinations and manifest")
    func installWritesTemplatesToProviderDestinationsAndManifest() throws {
        try Self.withTemporaryDirectory { directory in
            let installer = AgentIntegrationInstaller(
                resourcesDirectoryURL: Self.packageResourcesURL,
                supportDirectoryURL: directory.appending(path: "support", directoryHint: .isDirectory)
            )
            let home = directory.appending(path: "home", directoryHint: .isDirectory)
            let openCodeConfigHome = home
                .appending(path: ".config", directoryHint: .isDirectory)
                .appending(path: "opencode", directoryHint: .isDirectory)

            let openCode = try installer.install(
                provider: .openCode,
                setup: AgentIntegrationSetup(enabled: true, configHome: openCodeConfigHome.path),
                homeDirectory: home
            )
            let pi = try installer.install(
                provider: .pi,
                setup: AgentIntegrationSetup(enabled: true),
                homeDirectory: home
            )
            #expect(openCode.installedURL.path.hasSuffix(
                ".config/opencode/plugins/awesomux-opencode-status.js"
            ))
            #expect(pi.installedURL.path.hasSuffix(".pi/agent/extensions/awesomux-pi-status.ts"))
            #expect(FileManager.default.fileExists(atPath: openCode.installedURL.path))
            #expect(FileManager.default.fileExists(atPath: pi.installedURL.path))

            let openCodeData = try Data(contentsOf: openCode.installedURL)
            let piData = try Data(contentsOf: pi.installedURL)
            let renderedOpenCodeData = try Data(contentsOf: openCode.renderedInstall.renderedURL)
            let renderedPiData = try Data(contentsOf: pi.renderedInstall.renderedURL)
            #expect(openCodeData == renderedOpenCodeData)
            #expect(piData == renderedPiData)

            let manifest = try installer.loadManifest()
            #expect(manifest.records.count == 2)
            #expect(manifest.records.contains {
                $0.provider == .openCode && $0.installedPath == openCode.installedURL.path
            })
            #expect(manifest.records.contains {
                $0.provider == .pi && $0.installedPath == pi.installedURL.path
            })
        }
    }

    @Test("uninstall removes unchanged manifest-owned file")
    func uninstallRemovesUnchangedManifestOwnedFile() throws {
        try Self.withTemporaryDirectory { directory in
            let installer = AgentIntegrationInstaller(
                resourcesDirectoryURL: Self.packageResourcesURL,
                supportDirectoryURL: directory.appending(path: "support", directoryHint: .isDirectory)
            )
            let home = directory.appending(path: "home", directoryHint: .isDirectory)
            let setup = AgentIntegrationSetup(enabled: true)
            let installed = try installer.install(
                provider: .openCode,
                setup: setup,
                homeDirectory: home
            )

            let removedURL = try installer.uninstall(provider: .openCode)

            #expect(removedURL == installed.installedURL)
            #expect(!FileManager.default.fileExists(atPath: installed.installedURL.path))
            let manifest = try installer.loadManifest()
            #expect(manifest.records.first?.installedPath == nil)
        }
    }

    @Test("uninstall refuses modified installed file")
    func uninstallRefusesModifiedInstalledFile() throws {
        try Self.withTemporaryDirectory { directory in
            let installer = AgentIntegrationInstaller(
                resourcesDirectoryURL: Self.packageResourcesURL,
                supportDirectoryURL: directory.appending(path: "support", directoryHint: .isDirectory)
            )
            let home = directory.appending(path: "home", directoryHint: .isDirectory)
            let setup = AgentIntegrationSetup(enabled: true)
            let installed = try installer.install(
                provider: .pi,
                setup: setup,
                homeDirectory: home
            )
            try Data("// user edit\n".utf8).write(to: installed.installedURL)

            #expect(throws: AgentIntegrationInstallerError.installedFileModified(installed.installedURL)) {
                try installer.uninstall(provider: .pi)
            }
            #expect(FileManager.default.fileExists(atPath: installed.installedURL.path))
        }
    }

    @Test("reinstall to a new config home removes the previously installed file")
    func reinstallToNewConfigHomeRemovesPreviousFile() throws {
        try Self.withTemporaryDirectory { directory in
            let installer = AgentIntegrationInstaller(
                resourcesDirectoryURL: Self.packageResourcesURL,
                supportDirectoryURL: directory.appending(path: "support", directoryHint: .isDirectory)
            )
            let home = directory.appending(path: "home", directoryHint: .isDirectory)
            let firstConfigHome = directory
                .appending(path: "first", directoryHint: .isDirectory)
                .appending(path: "opencode", directoryHint: .isDirectory)
            let secondConfigHome = directory
                .appending(path: "second", directoryHint: .isDirectory)
                .appending(path: "opencode", directoryHint: .isDirectory)

            let first = try installer.install(
                provider: .openCode,
                setup: AgentIntegrationSetup(enabled: true, configHome: firstConfigHome.path),
                homeDirectory: home
            )
            #expect(FileManager.default.fileExists(atPath: first.installedURL.path))

            let second = try installer.install(
                provider: .openCode,
                setup: AgentIntegrationSetup(enabled: true, configHome: secondConfigHome.path),
                homeDirectory: home
            )

            // A changed config home moves the global destination; the prior file
            // must not be orphaned beyond uninstall's reach. Only the new file is
            // on disk after the move.
            #expect(first.installedURL.path != second.installedURL.path)
            #expect(!FileManager.default.fileExists(atPath: first.installedURL.path))
            #expect(FileManager.default.fileExists(atPath: second.installedURL.path))

            // Records are keyed by provider alone, so the two installs collapse
            // into a single record. File removal alone would also pass under a
            // two-record bug, so the count is what actually proves the move.
            let openCodeRecords = try installer.loadManifest().records.filter { $0.provider == .openCode }
            #expect(openCodeRecords.count == 1)
            #expect(openCodeRecords.first?.installedPath == second.installedURL.path)

            let removed = try installer.uninstall(provider: .openCode)
            #expect(removed == second.installedURL)
            #expect(!FileManager.default.fileExists(atPath: second.installedURL.path))
        }
    }

    @Test("reinstall to a new config home succeeds after the bundled template changes")
    func reinstallToNewConfigHomeSurvivesTemplateBump() throws {
        try Self.withTemporaryDirectory { directory in
            // A mutable resources mirror lets the test bump the bundled template
            // between installs, mimicking an app update that ships a new template
            // version.
            let resources = directory.appending(path: "resources", directoryHint: .isDirectory)
            let templateRelativePath = AgentIntegrationInstallProvider.openCode.templateRelativePath
            let templateURL = resources.appending(path: templateRelativePath)
            try FileManager.default.createDirectory(
                at: templateURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let bundledTemplate = Self.packageResourcesURL.appending(path: templateRelativePath)
            try FileManager.default.copyItem(at: bundledTemplate, to: templateURL)

            let installer = AgentIntegrationInstaller(
                resourcesDirectoryURL: resources,
                supportDirectoryURL: directory.appending(path: "support", directoryHint: .isDirectory)
            )
            let home = directory.appending(path: "home", directoryHint: .isDirectory)
            let firstConfigHome = directory
                .appending(path: "first", directoryHint: .isDirectory)
                .appending(path: "opencode", directoryHint: .isDirectory)
            let secondConfigHome = directory
                .appending(path: "second", directoryHint: .isDirectory)
                .appending(path: "opencode", directoryHint: .isDirectory)

            let first = try installer.install(
                provider: .openCode,
                setup: AgentIntegrationSetup(enabled: true, configHome: firstConfigHome.path),
                homeDirectory: home
            )
            #expect(FileManager.default.fileExists(atPath: first.installedURL.path))

            // Ship a new template version. The prior install's rendered copy still
            // reflects v1, so orphan removal must compare the old installed file
            // against that v1 rendered content, not the freshly rendered v2.
            try Data("// bundled template v2\n".utf8).write(to: templateURL)

            // The first install was unmodified by the user, so reinstalling to a
            // new config home must succeed rather than misreport the stale-template
            // file as user-modified.
            let second = try installer.install(
                provider: .openCode,
                setup: AgentIntegrationSetup(enabled: true, configHome: secondConfigHome.path),
                homeDirectory: home
            )

            #expect(first.installedURL.path != second.installedURL.path)
            #expect(!FileManager.default.fileExists(atPath: first.installedURL.path))
            #expect(FileManager.default.fileExists(atPath: second.installedURL.path))

            let openCodeRecords = try installer.loadManifest().records.filter { $0.provider == .openCode }
            #expect(openCodeRecords.count == 1)
            #expect(openCodeRecords.first?.installedPath == second.installedURL.path)

            // uninstall must also succeed: the recorded rendered copy now reflects
            // v2 and matches the v2 install on disk.
            let removed = try installer.uninstall(provider: .openCode)
            #expect(removed == second.installedURL)
            #expect(!FileManager.default.fileExists(atPath: second.installedURL.path))
        }
    }

    @Test("failed reinstall keeps the modified prior file tracked for manual removal")
    func failedReinstallKeepsModifiedPriorFileTracked() throws {
        try Self.withTemporaryDirectory { directory in
            let installer = AgentIntegrationInstaller(
                resourcesDirectoryURL: Self.packageResourcesURL,
                supportDirectoryURL: directory.appending(path: "support", directoryHint: .isDirectory)
            )
            let home = directory.appending(path: "home", directoryHint: .isDirectory)
            let firstConfigHome = directory
                .appending(path: "first", directoryHint: .isDirectory)
                .appending(path: "opencode", directoryHint: .isDirectory)
            let secondConfigHome = directory
                .appending(path: "second", directoryHint: .isDirectory)
                .appending(path: "opencode", directoryHint: .isDirectory)

            let first = try installer.install(
                provider: .openCode,
                setup: AgentIntegrationSetup(enabled: true, configHome: firstConfigHome.path),
                homeDirectory: home
            )

            // A user edit to the installed file makes the orphan-removal step of
            // the next install refuse to delete it.
            try Data("// user edit\n".utf8).write(to: first.installedURL)

            // Reinstalling to a new config home moves the destination, which
            // forces removeManagedFile(first) to run and throw on the modified
            // file. render() ran first, but it must not have erased the prior
            // installedPath: the file is still on disk and must stay reachable
            // by the "Remove" recovery path.
            #expect(throws: AgentIntegrationInstallerError.installedFileModified(first.installedURL)) {
                try installer.install(
                    provider: .openCode,
                    setup: AgentIntegrationSetup(enabled: true, configHome: secondConfigHome.path),
                    homeDirectory: home
                )
            }

            #expect(FileManager.default.fileExists(atPath: first.installedURL.path))
            let record = try installer.loadManifest().records.first { $0.provider == .openCode }
            #expect(record?.installedPath == first.installedURL.path)

            // The manual-cleanup path is still wired: uninstall re-throws on the
            // modified file rather than silently losing track of it.
            #expect(throws: AgentIntegrationInstallerError.installedFileModified(first.installedURL)) {
                try installer.uninstall(provider: .openCode)
            }
        }
    }

    @Test("install preserves existing provider directory permissions")
    func installPreservesExistingProviderDirectoryPermissions() throws {
        try Self.withTemporaryDirectory { directory in
            let installer = AgentIntegrationInstaller(
                resourcesDirectoryURL: Self.packageResourcesURL,
                supportDirectoryURL: directory.appending(path: "support", directoryHint: .isDirectory)
            )
            let home = directory.appending(path: "home", directoryHint: .isDirectory)
            let configHome = home
                .appending(path: ".config", directoryHint: .isDirectory)
                .appending(path: "opencode", directoryHint: .isDirectory)
            let pluginsDirectory = configHome.appending(path: "plugins", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(
                at: pluginsDirectory,
                withIntermediateDirectories: true
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: pluginsDirectory.path
            )

            let installed = try installer.install(
                provider: .openCode,
                setup: AgentIntegrationSetup(enabled: true, configHome: configHome.path),
                homeDirectory: home
            )

            #expect(try Self.permissions(at: pluginsDirectory) == 0o755)
            #expect(try Self.permissions(at: installed.installedURL) == 0o600)
        }
    }

    @Test("global destinations match provider conventions")
    func destinationPathsMatchProviderConventions() throws {
        try Self.withTemporaryDirectory { directory in
            let installer = AgentIntegrationInstaller(
                resourcesDirectoryURL: Self.packageResourcesURL,
                supportDirectoryURL: directory.appending(path: "support", directoryHint: .isDirectory)
            )
            let home = directory.appending(path: "home", directoryHint: .isDirectory)

            let openCodeGlobal = try installer.destinationFileURL(
                provider: .openCode,
                homeDirectory: home
            )
            let piGlobal = try installer.destinationFileURL(
                provider: .pi,
                homeDirectory: home
            )
            #expect(openCodeGlobal.path.hasSuffix(".config/opencode/plugins/awesomux-opencode-status.js"))
            #expect(piGlobal.path.hasSuffix(".pi/agent/extensions/awesomux-pi-status.ts"))
        }
    }

    @Test("disabled setup cannot render or install")
    func disabledSetupCannotRenderOrInstall() throws {
        try Self.withTemporaryDirectory { directory in
            let installer = AgentIntegrationInstaller(
                resourcesDirectoryURL: Self.packageResourcesURL,
                supportDirectoryURL: directory.appending(path: "support", directoryHint: .isDirectory)
            )
            let home = directory.appending(path: "home", directoryHint: .isDirectory)

            #expect(throws: AgentIntegrationInstallerError.providerDisabled(.openCode)) {
                try installer.render(provider: .openCode, setup: .defaultValue)
            }
            #expect(throws: AgentIntegrationInstallerError.providerDisabled(.pi)) {
                try installer.install(
                    provider: .pi,
                    setup: .defaultValue,
                    homeDirectory: home
                )
            }
        }
    }

    @Test("validates executable paths")
    func validatesExecutablePaths() throws {
        try Self.withTemporaryDirectory { directory in
            let executable = directory.appending(path: "opencode")
            FileManager.default.createFile(atPath: executable.path, contents: Data("#!/bin/sh\n".utf8))
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: executable.path
            )
            let nonExecutable = directory.appending(path: "pi")
            FileManager.default.createFile(atPath: nonExecutable.path, contents: nil)

            let installer = AgentIntegrationInstaller(
                resourcesDirectoryURL: Self.packageResourcesURL,
                supportDirectoryURL: directory.appending(path: "support", directoryHint: .isDirectory)
            )

            #expect(try installer.validateExecutablePath(executable.path) == executable)
            #expect(throws: AgentIntegrationInstallerError.executableNotExecutable(nonExecutable)) {
                try installer.validateExecutablePath(nonExecutable.path)
            }
            #expect(throws: AgentIntegrationInstallerError.invalidPath("relative/pi")) {
                try installer.validateExecutablePath("relative/pi")
            }
        }
    }

    @Test("prepare config home creates directories and rejects files")
    func prepareConfigHomeCreatesDirectoriesAndRejectsFiles() throws {
        try Self.withTemporaryDirectory { directory in
            let installer = AgentIntegrationInstaller(
                resourcesDirectoryURL: Self.packageResourcesURL,
                supportDirectoryURL: directory.appending(path: "support", directoryHint: .isDirectory)
            )
            let configHome = directory
                .appending(path: "home", directoryHint: .isDirectory)
                .appending(path: ".config", directoryHint: .isDirectory)
                .appending(path: "opencode", directoryHint: .isDirectory)
            let file = directory.appending(path: "not-a-directory")
            FileManager.default.createFile(atPath: file.path, contents: nil)

            let prepared = try installer.prepareConfigHome(configHome.path)
            #expect(prepared == configHome)
            #expect(FileManager.default.fileExists(atPath: configHome.path))
            #expect(throws: AgentIntegrationInstallerError.configHomeIsNotDirectory(
                URL(fileURLWithPath: file.path, isDirectory: true)
            )) {
                try installer.prepareConfigHome(file.path)
            }
        }
    }

    @Test("future manifest versions are rejected")
    func futureManifestVersionsAreRejected() throws {
        try Self.withTemporaryDirectory { supportDirectory in
            let installer = AgentIntegrationInstaller(
                resourcesDirectoryURL: Self.packageResourcesURL,
                supportDirectoryURL: supportDirectory
            )
            try FileManager.default.createDirectory(
                at: installer.rootDirectoryURL,
                withIntermediateDirectories: true
            )
            let unsupportedVersion = AgentIntegrationInstallManifest.currentVersion + 1
            let data = Data(#"{"records":[],"version":\#(unsupportedVersion)}"#.utf8)
            try data.write(to: installer.manifestURL)

            #expect(throws: AgentIntegrationInstallerError.unsupportedManifestVersion(unsupportedVersion)) {
                try installer.loadManifest()
            }
        }
    }

    private static func withTemporaryDirectory(_ operation: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "awesomux-agent-integration-installer-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try operation(directory)
    }

    private static func startExternalLockHolder(in directory: URL) throws -> Process {
        let readyURL = directory.appending(path: "lock-ready")
        let script = """
        import fcntl, os, sys, time
        os.makedirs(sys.argv[1], exist_ok=True)
        lock = open(os.path.join(sys.argv[1], ".install-state.lock"), "a+")
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        open(sys.argv[2], "w").close()
        time.sleep(30)
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", script, directory.path, readyURL.path]
        try process.run()

        for _ in 0..<100 where !FileManager.default.fileExists(atPath: readyURL.path) {
            Thread.sleep(forTimeInterval: 0.01)
        }
        try #require(FileManager.default.fileExists(atPath: readyURL.path))
        return process
    }

    private static func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let rawPermissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        return rawPermissions & 0o777
    }

    private static func record(
        provider: AgentIntegrationInstallProvider,
        installedPath: String
    ) -> AgentIntegrationInstallRecord {
        AgentIntegrationInstallRecord(
            provider: provider,
            binaryPath: nil,
            configHome: nil,
            templatePath: "/tmp/template",
            renderedPath: "/tmp/rendered",
            installedPath: installedPath
        )
    }

    private static func writeManifest(_ manifest: AgentIntegrationInstallManifest, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(manifest).write(to: url, options: .atomic)
    }

    private static var packageResourcesURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Resources", directoryHint: .isDirectory)
    }
}
