import AwesoMuxConfig
import Foundation

// These defaults are never reached: every fixture supplies its own directories.
enum SessionPersistence {
    static var supportDirectoryURL: URL { URL(fileURLWithPath: "/unused-opencode-fixture") }
}
enum AppRuntimeProfile {
    case development(worktreeID: String?)
    var supportDirectoryURL: URL { URL(fileURLWithPath: "/unused-opencode-fixture") }
}

@main
struct InstallerDriver {
    static func main() throws {
        let manager = FileManager.default
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let resources = root.appending(path: "Resources")
        try manager.copyItem(at: URL(fileURLWithPath: CommandLine.arguments[2]), to: resources)
        let support = root.appending(path: "support")
        let home = root.appending(path: "home")
        let installer = AgentIntegrationInstaller(resourcesDirectoryURL: resources, supportDirectoryURL: support)
        let setup = AgentIntegrationSetup(enabled: true)
        let template = installer.templateURL(provider: .openCode)
        let installed = try installer.install(provider: .openCode, setup: setup, homeDirectory: home)
        try require(try installer.loadManifest().version == 2, "package ownership uses manifest v2")
        let entry = installed.installedURL
        let client = entry.deletingLastPathComponent().appending(path: "tui.js")
        try require(entry.path.hasSuffix("plugins/awesomux-opencode-status/index.js"), "package entry path")
        try require(manager.fileExists(atPath: client.path), "client part installed")
        let bridge = entry.deletingLastPathComponent().deletingLastPathComponent().appending(path: "awesomux-opencode-status.js")
        try require(manager.fileExists(atPath: bridge.path), "V1 discovery bridge installed")
        let originalBridge = try Data(contentsOf: bridge)
        try Data("// modified V1 bridge".utf8).write(to: bridge)
        try require(
            installer.installedContentDiffersFromTemplate(installedPath: entry.path, templateURL: template), "modified bridge status")
        try expectModified { _ = try installer.install(provider: .openCode, setup: setup, homeDirectory: home) }
        try expectModified { _ = try installer.uninstall(provider: .openCode) }
        try require(manager.fileExists(atPath: entry.path), "modified bridge preserves package")
        try originalBridge.write(to: bridge)
        try manager.removeItem(at: bridge)
        try require(
            installer.installedContentDiffersFromTemplate(installedPath: entry.path, templateURL: template), "missing bridge status")
        _ = try installer.install(provider: .openCode, setup: setup, homeDirectory: home)
        try require(try Data(contentsOf: bridge) == originalBridge, "repair restores bridge")
        try require(
            !installer.installedContentDiffersFromTemplate(installedPath: entry.path, templateURL: template), "current package status")
        let originalClient = try Data(contentsOf: client)
        try Data("// modified client".utf8).write(to: client)
        try require(
            installer.installedContentDiffersFromTemplate(installedPath: entry.path, templateURL: template), "modified client status")
        try expectModified { _ = try installer.uninstall(provider: .openCode) }
        try require(manager.fileExists(atPath: entry.path), "modified client preserves server")
        try originalClient.write(to: client)
        let extra = entry.deletingLastPathComponent().appending(path: "user.js")
        try Data("user content".utf8).write(to: extra)
        try expectModified { _ = try installer.uninstall(provider: .openCode) }
        try require(manager.fileExists(atPath: extra.path), "unowned package file preserved")
        try manager.removeItem(at: extra)
        try manager.removeItem(at: client)
        try require(
            installer.installedContentDiffersFromTemplate(installedPath: entry.path, templateURL: template), "missing client status")
        _ = try installer.install(provider: .openCode, setup: setup, homeDirectory: home)
        try require(try Data(contentsOf: client) == originalClient, "repair restores client")

        let failing = AgentIntegrationInstaller(
            resourcesDirectoryURL: resources, supportDirectoryURL: support,
            manifestWriter: { _ in throw CocoaError(.fileWriteUnknown) })
        let secondSetup = AgentIntegrationSetup(enabled: true, configHome: root.appending(path: "second").path)
        do {
            _ = try failing.install(provider: .openCode, setup: secondSetup, homeDirectory: home)
            throw CheckFailure.failed("expected manifest failure")
        } catch is CocoaError {}
        try require(manager.fileExists(atPath: entry.path) && manager.fileExists(atPath: client.path), "moved package rollback")
        let secondEntry = try installer.destinationFileURL(
            provider: .openCode, homeDirectory: home, configuredConfigHome: secondSetup.configHome)
        try require(!manager.fileExists(atPath: secondEntry.deletingLastPathComponent().path), "rollback removes new package directory")
        do {
            _ = try failing.uninstall(provider: .openCode)
            throw CheckFailure.failed("expected uninstall manifest failure")
        } catch is CocoaError {}
        try require(try Data(contentsOf: client) == originalClient, "uninstall rollback restores client")
        try require(try Data(contentsOf: bridge) == originalBridge, "uninstall rollback restores bridge")
        _ = try installer.uninstall(provider: .openCode)
        try require(!manager.fileExists(atPath: entry.deletingLastPathComponent().path), "uninstall removes package directory")
        try require(!manager.fileExists(atPath: bridge.path), "uninstall removes bridge")

        let legacy = entry.deletingLastPathComponent().deletingLastPathComponent().appending(path: "awesomux-opencode-status.js")
        let legacyRendered = installer.renderedFileURL(provider: .openCode, setup: setup)
            .deletingLastPathComponent().deletingLastPathComponent().appending(path: "awesomux-opencode-status.js")
        let legacyData = Data("// owned v1 plugin".utf8)
        try legacyData.write(to: legacy)
        try legacyData.write(to: legacyRendered)
        try expectModified { _ = try installer.install(provider: .openCode, setup: setup, homeDirectory: home) }
        try require(try Data(contentsOf: legacy) == legacyData, "untracked legacy preserved")
        let record = AgentIntegrationInstallRecord(
            provider: .openCode, binaryPath: nil, configHome: nil,
            templatePath: template.path, renderedPath: legacyRendered.path, installedPath: legacy.path)
        try JSONEncoder().encode(AgentIntegrationInstallManifest(version: 1, records: [record])).write(to: installer.manifestURL)
        try require(
            installer.installedContentDiffersFromTemplate(installedPath: legacy.path, templateURL: template), "legacy install offers repair"
        )
        try Data("// user-edited legacy".utf8).write(to: legacy)
        try expectModified { _ = try installer.install(provider: .openCode, setup: setup, homeDirectory: home) }
        try require(manager.fileExists(atPath: legacy.path), "modified legacy preserved")
        try legacyData.write(to: legacy)
        _ = try installer.install(provider: .openCode, setup: setup, homeDirectory: home)
        try require(try Data(contentsOf: legacy) == originalBridge, "legacy entry replaced with V1 discovery bridge")
        try require(try installer.loadManifest().version == 2, "legacy manifest upgrades on migration")
        try require(
            manager.fileExists(atPath: entry.path) && manager.fileExists(atPath: client.path), "legacy migration installs both parts")
        _ = try installer.uninstall(provider: .openCode)

        let pi = try installer.install(provider: .pi, setup: setup, homeDirectory: home)
        try require(pi.installedURL.lastPathComponent == "awesomux-pi-status.ts", "Pi remains single file")
        _ = try installer.uninstall(provider: .pi)
        try require(try installer.loadManifest().records.isEmpty, "manifest empty after removal")
        print(
            "PASS: package install, stale/repair, modified/unowned-file protection, move/uninstall rollback, legacy migration, Pi isolation"
        )
    }

    enum CheckFailure: Error { case failed(String) }

    static func require(_ condition: Bool, _ label: String) throws {
        guard condition else { throw CheckFailure.failed(label) }
    }

    static func expectModified(_ operation: () throws -> Void) throws {
        do {
            try operation()
            throw CheckFailure.failed("expected modified-file refusal")
        } catch AgentIntegrationInstallerError.installedFileModified {}
    }
}
