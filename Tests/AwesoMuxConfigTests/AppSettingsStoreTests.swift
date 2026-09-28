import Foundation
import Testing
@testable import AwesoMuxConfig

@MainActor
@Suite("AppSettingsStore")
struct AppSettingsStoreTests {
    private let codec = TOMLConfigCodec()

    @Test("UI settings change preserves unknown [terminal] lines on disk")
    func updatePreservesUnknownTerminalLines() throws {
        let fixture = try TemporaryAppSettingsFixture()
        defer { fixture.cleanUp() }
        // A user's hand-written terminal key the app doesn't own.
        let onDisk = try codec.encodeString(.defaultValue).replacingOccurrences(
            of: #"clipboard_write_policy = "ask""#,
            with: """
            clipboard_write_policy = "ask"
            custom_shell_integration = true
            """
        )
        try fixture.writeConfig(onDisk)
        let store = AppSettingsStore(fileStore: fixture.store, legacySnapshotProvider: { nil })
        store.bootstrap()

        // The unknown line must load into the store's pass-through state, not
        // just into a transient codec result.
        #expect(store.config.unknownTerminalTableLines.contains("custom_shell_integration = true"))

        // A UI-driven settings change rebuilds the config from the section
        // stores; it must NOT drop the user's custom terminal line.
        store.update { $0.terminal.copyOnSelect = .on }

        let reread = try String(contentsOf: fixture.configURL, encoding: .utf8)
        #expect(reread.contains("custom_shell_integration = true"))
        #expect(reread.contains(#"copy_on_select = "on""#))
        #expect(throws: Never.self) { try codec.decode(reread) }
    }

    @Test("UI settings change keeps leading terminal extras outside multiline values")
    func updateKeepsLeadingTerminalExtrasOutsideMultilineValues() throws {
        let fixture = try TemporaryAppSettingsFixture()
        defer { fixture.cleanUp() }
        let onDisk = [
            "[terminal]",
            "",
            "   ",
            #"copy_on_select = "off""#,
            "custom_note = \"\"\"",
            "first line",
            "\"\"\"",
        ].joined(separator: "\n")
        try fixture.writeConfig(onDisk)
        let store = AppSettingsStore(fileStore: fixture.store, legacySnapshotProvider: { nil })
        store.bootstrap()

        store.update { $0.terminal.copyOnSelect = .on }

        let reread = try String(contentsOf: fixture.configURL, encoding: .utf8)
        let redecoded = try codec.decode(reread)
        #expect(
            reread.contains(
                """
                custom_note = \"\"\"
                first line
                \"\"\"
                """))
        #expect(redecoded.terminal.copyOnSelect == .on)
    }

    @Test("reload from disk preserves current config when TOML is invalid")
    func reloadFromDiskPreservesCurrentConfigWhenTOMLIsInvalid() throws {
        let fixture = try TemporaryAppSettingsFixture()
        defer { fixture.cleanUp() }
        let currentConfig = AwesoMuxConfig(appearance: AppearanceConfig(theme: .light, accent: .green))
        try fixture.writeConfig(try codec.encodeString(currentConfig))
        let store = AppSettingsStore(fileStore: fixture.store, legacySnapshotProvider: { nil })
        store.bootstrap()
        let invalidTOML = """
        [appearance]
        theme =
        """
        try fixture.writeConfig(invalidTOML)

        store.reloadFromDisk()
        let fileContents = try String(contentsOf: fixture.configURL, encoding: .utf8)

        #expect(store.config == currentConfig)
        #expect(store.loadSource == .invalidExistingFile)
        #expect(store.isDiskConfigInvalid)
        #expect(store.latestError != nil)
        #expect(fileContents == invalidTOML)
    }

    @Test("replace invalid file with current config overwrites disk and clears invalid state")
    func replaceInvalidFileWithCurrentConfigOverwritesDiskAndClearsInvalidState() throws {
        let fixture = try TemporaryAppSettingsFixture()
        defer { fixture.cleanUp() }
        let currentConfig = AwesoMuxConfig(workspaces: WorkspaceConfig(defaultGroup: "Support"))
        try fixture.writeConfig(try codec.encodeString(currentConfig))
        let store = AppSettingsStore(fileStore: fixture.store, legacySnapshotProvider: { nil })
        store.bootstrap()
        try fixture.writeConfig("[appearance]\ntheme =")
        store.reloadFromDisk()

        store.replaceInvalidFileWithCurrentConfig()
        let decoded = try codec.decode(Data(contentsOf: fixture.configURL))

        #expect(decoded == currentConfig)
        #expect(store.config == currentConfig)
        #expect(store.loadSource == .existingFile)
        #expect(store.latestError == nil)
        #expect(!store.isDiskConfigInvalid)
    }

    @Test("failed invalid-file replacement preserves v1 memory and invalid disk bytes")
    func failedReplacementPreservesMemoryAndDisk() throws {
        let fixture = try TemporaryAppSettingsFixture()
        defer { fixture.cleanUp() }
        var v1 = AwesoMuxConfig.defaultValue
        v1.advanced.configSchemaVersion = 1
        try fixture.writeConfig(try codec.encodeString(v1))
        let store = AppSettingsStore(fileStore: fixture.store, legacySnapshotProvider: { nil })
        store.bootstrap()
        let invalidBytes = Data("[appearance]\ntheme =".utf8)
        try invalidBytes.write(to: fixture.configURL)
        store.reloadFromDisk()
        let previous = store.config
        let failure = ConfigFileStoreError.cannotWrite(fixture.configURL, message: "denied")
        store.saveToDisk = { _ throws(ConfigFileStoreError) in throw failure }

        store.replaceInvalidFileWithCurrentConfig()

        #expect(store.config == previous)
        #expect(store.isDiskConfigInvalid)
        #expect(store.latestError == .save(failure))
        #expect(try Data(contentsOf: fixture.configURL) == invalidBytes)
    }

    @Test("GUI update while disk config is invalid does not clobber invalid file")
    func guiUpdateWhileDiskConfigIsInvalidDoesNotClobberInvalidFile() throws {
        let fixture = try TemporaryAppSettingsFixture()
        defer { fixture.cleanUp() }
        let currentConfig = AwesoMuxConfig(notifications: NotificationConfig(muted: false, sound: true))
        try fixture.writeConfig(try codec.encodeString(currentConfig))
        let store = AppSettingsStore(fileStore: fixture.store, legacySnapshotProvider: { nil })
        store.bootstrap()
        let invalidTOML = "[appearance]\ntheme ="
        try fixture.writeConfig(invalidTOML)
        store.reloadFromDisk()

        store.update { config in
            config.notifications.muted = true
        }
        let fileContents = try String(contentsOf: fixture.configURL, encoding: .utf8)

        #expect(store.config.notifications.muted)
        #expect(store.isDiskConfigInvalid)
        #expect(fileContents == invalidTOML)
    }

    @Test("save failure is surfaced and in-memory config is left unchanged")
    func saveFailureIsSurfaced() throws {
        let fixture = try TemporaryAppSettingsFixture()
        defer { fixture.cleanUp() }
        let failure = ConfigFileStoreError.cannotWrite(fixture.configURL, message: "denied")
        let store = AppSettingsStore(fileStore: fixture.store, legacySnapshotProvider: { nil })

        store.bootstrap()
        store.saveToDisk = { (_) throws(ConfigFileStoreError) in throw failure }
        store.update { config in
            config.notifications.muted = true
        }

        // Transactional update: a save failure does NOT leak the
        // mutation into in-memory state. The previous behaviour silently
        // diverged memory from disk; now they stay consistent and the
        // error surfaces.
        #expect(!store.config.notifications.muted)
        #expect(store.latestError == .save(failure))
    }

    @Test("invalid disk config is surfaced and not overwritten")
    func invalidDiskConfigIsSurfacedAndNotOverwritten() throws {
        let fixture = try TemporaryAppSettingsFixture()
        defer { fixture.cleanUp() }
        let invalidTOML = """
        [appearance]
        theme =
        """
        try fixture.writeConfig(invalidTOML)
        let store = AppSettingsStore(fileStore: fixture.store, legacySnapshotProvider: { nil })

        store.bootstrap()
        store.update { config in
            config.notifications.muted = true
        }
        let fileContents = try String(contentsOf: fixture.configURL, encoding: .utf8)

        #expect(store.config.notifications.muted)
        #expect(store.loadSource == .invalidExistingFile)
        #expect(store.isDiskConfigInvalid)
        #expect(store.latestError != nil)
        #expect(fileContents == invalidTOML)
    }
}

private struct TemporaryAppSettingsFixture {
    let homeURL: URL
    let configDirectoryURL: URL
    let configURL: URL
    let store: ConfigFileStore

    init() throws {
        homeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("awesomux-app-settings-tests-\(UUID().uuidString)", isDirectory: true)
        let resolver = ConfigPathResolver(homeDirectory: homeURL)
        configDirectoryURL = resolver.configDirectoryURL
        configURL = resolver.configFileURL
        store = ConfigFileStore(pathResolver: resolver)
    }

    func writeConfig(_ toml: String) throws {
        try FileManager.default.createDirectory(
            at: configDirectoryURL,
            withIntermediateDirectories: true
        )
        try toml.write(to: configURL, atomically: false, encoding: .utf8)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: homeURL)
    }
}

@MainActor
@Suite("App settings diagnostics")
struct AppSettingsDiagnosticEventTests {
    @Test("manual and watched reloads emit structured outcomes")
    func reloadOutcomes() throws {
        let fixture = try TemporaryAppSettingsFixture()
        defer { fixture.cleanUp() }
        try fixture.writeConfig("[appearance]\ntheme = \"dark\"\n")
        var events: [AppSettingsDiagnosticEvent] = []
        let store = AppSettingsStore(
            fileStore: fixture.store,
            diagnosticEventHandler: { events.append($0) },
            legacySnapshotProvider: { nil }
        )
        store.bootstrap()

        try fixture.writeConfig("[appearance]\ntheme =")
        store.reloadFromDisk()
        #expect(events.last == .reloadRejected(trigger: .manual))

        try fixture.writeConfig("[appearance]\ntheme = \"light\"\n")
        store.handleWatchedConfigDirectoryChange()
        #expect(events.last == .reloadSucceeded(trigger: .watcher))
    }

    @Test("failed reset after deletion emits a rejected outcome")
    func failedResetOutcome() throws {
        let fixture = try TemporaryAppSettingsFixture()
        defer { fixture.cleanUp() }
        var events: [AppSettingsDiagnosticEvent] = []
        let store = AppSettingsStore(
            fileStore: fixture.store,
            diagnosticEventHandler: { events.append($0) },
            legacySnapshotProvider: { nil }
        )
        store.bootstrap()
        try FileManager.default.removeItem(at: fixture.configURL)
        store.saveToDisk = { _ throws(ConfigFileStoreError) in
            throw .cannotWrite(fixture.configURL, message: "denied")
        }

        store.reloadFromDisk()

        #expect(events.last == .resetAfterDeletionRejected)
        #expect(store.latestError != nil)
    }
}
