import Foundation
import Testing
@testable import AwesoMuxConfig

@MainActor
@Suite("AppSettingsStore")
struct AppSettingsStoreTests {
    private let codec = TOMLConfigCodec()

    @Test("bootstrap loads existing TOML config into current config")
    func bootstrapLoadsExistingTOMLConfigIntoCurrentConfig() throws {
        let fixture = try TemporaryAppSettingsFixture()
        defer { fixture.cleanUp() }
        let config = AwesoMuxConfig(
            appearance: AppearanceConfig(theme: .dark, accent: .green, glowStrength: 0.2),
            notifications: NotificationConfig(muted: true, sound: false)
        )
        try fixture.writeConfig(try codec.encodeString(config))
        let store = AppSettingsStore(fileStore: fixture.store, legacySnapshotProvider: { nil })

        store.bootstrap()

        #expect(store.config == config)
        #expect(store.loadSource == .existingFile)
        #expect(store.latestError == nil)
        #expect(!store.isDiskConfigInvalid)
    }

    @Test("bootstrap creates default config when missing")
    func bootstrapCreatesDefaultConfigWhenMissing() throws {
        let fixture = try TemporaryAppSettingsFixture()
        defer { fixture.cleanUp() }
        let store = AppSettingsStore(fileStore: fixture.store, legacySnapshotProvider: { nil })

        store.bootstrap()
        let decoded = try codec.decode(Data(contentsOf: fixture.configURL))

        #expect(store.config == .defaultValue)
        #expect(decoded == .defaultValue)
        #expect(store.loadSource == .createdDefault)
        #expect(store.latestError == nil)
    }

    @Test("bootstrap creates migrated config when missing")
    func bootstrapCreatesMigratedConfigWhenMissing() throws {
        let fixture = try TemporaryAppSettingsFixture()
        defer { fixture.cleanUp() }
        let snapshot = LegacySettingsSnapshot(
            theme: "latte",
            accentColor: "sapphire",
            glowStrength: 0.4,
            notificationsMuted: true,
            notificationSoundEnabled: false,
            respectDoNotDisturb: false,
            rememberToolTrust: false,
            defaultWorkspaceGroup: "Ops",
            outputMarksNeedsAttention: false
        )
        let store = AppSettingsStore(fileStore: fixture.store, legacySnapshotProvider: { snapshot })

        store.bootstrap()
        let decoded = try codec.decode(Data(contentsOf: fixture.configURL))

        #expect(store.config == snapshot.migratedConfig())
        #expect(decoded == snapshot.migratedConfig())
        #expect(store.loadSource == .migratedLegacy)
        #expect(store.latestError == nil)
    }

    @Test("update writes changed config to disk")
    func updateWritesChangedConfigToDisk() throws {
        let fixture = try TemporaryAppSettingsFixture()
        defer { fixture.cleanUp() }
        let store = AppSettingsStore(fileStore: fixture.store, legacySnapshotProvider: { nil })
        store.bootstrap()

        store.update { config in
            config.appearance.theme = .light
            config.workspaces.defaultGroup = "Clients"
        }
        let decoded = try codec.decode(Data(contentsOf: fixture.configURL))

        #expect(store.config.appearance.theme == .light)
        #expect(decoded.appearance.theme == .light)
        #expect(decoded.workspaces.defaultGroup == "Clients")
        #expect(store.latestError == nil)
    }

    @Test("agent integration section store writes setup paths")
    func agentIntegrationSectionStoreWritesSetupPaths() throws {
        let fixture = try TemporaryAppSettingsFixture()
        defer { fixture.cleanUp() }
        let store = AppSettingsStore(fileStore: fixture.store, legacySnapshotProvider: { nil })
        store.bootstrap()

        store.agentIntegrations.update { integrations in
            integrations.openCode = AgentIntegrationSetup(
                enabled: true,
                binaryPath: "/opt/homebrew/bin/opencode",
                configHome: "/Users/example/.config/opencode"
            )
            integrations.pi = AgentIntegrationSetup(
                binaryPath: "/opt/homebrew/bin/pi",
                configHome: "/Users/example/.pi/agent"
            )
        }

        let decoded = try codec.decode(Data(contentsOf: fixture.configURL))

        #expect(decoded.agentIntegrations == store.agentIntegrations.value)
        #expect(decoded.agentIntegrations.openCode.enabled)
        #expect(!decoded.agentIntegrations.pi.enabled)
        #expect(decoded.agentIntegrations.openCode.binaryPath == "/opt/homebrew/bin/opencode")
        #expect(decoded.agentIntegrations.pi.configHome == "/Users/example/.pi/agent")
        #expect(store.latestError == nil)
    }

    @Test("keyboard section store writes custom shortcuts")
    func keyboardSectionStoreWritesCustomShortcuts() throws {
        let fixture = try TemporaryAppSettingsFixture()
        defer { fixture.cleanUp() }
        let store = AppSettingsStore(fileStore: fixture.store, legacySnapshotProvider: { nil })
        store.bootstrap()

        store.keyboard.update { keyboard in
            keyboard.shortcuts["toggleFloatingPanel"] = ShortcutBindingConfig(
                key: ";",
                modifiers: [.command, .option]
            )
        }

        let decoded = try codec.decode(Data(contentsOf: fixture.configURL))

        #expect(decoded.keyboard == store.keyboard.value)
        #expect(decoded.keyboard.shortcuts["toggleFloatingPanel"]?.key == ";")
        #expect(decoded.keyboard.shortcuts["toggleFloatingPanel"]?.modifiers == [.command, .option])
        #expect(store.latestError == nil)
    }

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

    @Test("reload from disk loads valid external changes")
    func reloadFromDiskLoadsValidExternalChanges() throws {
        let fixture = try TemporaryAppSettingsFixture()
        defer { fixture.cleanUp() }
        let store = AppSettingsStore(fileStore: fixture.store, legacySnapshotProvider: { nil })
        store.bootstrap()
        let externalConfig = AwesoMuxConfig(
            appearance: AppearanceConfig(theme: .dark, accent: .mauve, glowStrength: 0.3),
            notifications: NotificationConfig(muted: true, sound: false)
        )
        try fixture.writeConfig(try codec.encodeString(externalConfig))

        store.reloadFromDisk()

        #expect(store.config == externalConfig)
        #expect(store.loadSource == .existingFile)
        #expect(store.latestError == nil)
        #expect(!store.isDiskConfigInvalid)
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

    @Test("reload from disk resets to defaults when the config file is deleted")
    func reloadFromDiskResetsToDefaultsWhenFileIsDeleted() throws {
        let fixture = try TemporaryAppSettingsFixture()
        defer { fixture.cleanUp() }
        let store = AppSettingsStore(fileStore: fixture.store, legacySnapshotProvider: { nil })
        store.bootstrap()
        store.update { config in
            config.workspaces.defaultGroup = "Clients"
        }
        try FileManager.default.removeItem(at: fixture.configURL)

        store.reloadFromDisk()
        let decoded = try codec.decode(Data(contentsOf: fixture.configURL))

        // Manual deletion of config.toml means "factory reset" — the
        // user's in-memory tweaks (defaultGroup = "Clients") are
        // intentionally discarded rather than re-written to disk.
        #expect(decoded == .defaultValue)
        #expect(store.config == .defaultValue)
        #expect(store.loadSource == .createdDefault)
        #expect(store.latestError == nil)
        #expect(!store.isDiskConfigInvalid)
    }

    @Test("self write directory change is ignored")
    func selfWriteDirectoryChangeIsIgnored() throws {
        let fixture = try TemporaryAppSettingsFixture()
        defer { fixture.cleanUp() }
        let store = AppSettingsStore(fileStore: fixture.store, legacySnapshotProvider: { nil })
        store.bootstrap()

        store.update { config in
            config.appearance.theme = .dark
        }

        store.handleWatchedConfigDirectoryChange()

        #expect(store.config.appearance.theme == .dark)
    }

    @Test("watcher can be started and stopped more than once")
    func watcherCanBeStartedAndStoppedMoreThanOnce() throws {
        let fixture = try TemporaryAppSettingsFixture()
        defer { fixture.cleanUp() }
        let store = AppSettingsStore(
            fileStore: fixture.store,
            watchDebounceNanoseconds: 1_000,
            legacySnapshotProvider: { nil }
        )
        store.bootstrap()

        store.startWatching()
        store.startWatching()
        store.stopWatching()
        store.stopWatching()

        #expect(!store.isExternalReloadPending)
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

    @Test("silent synchronization closes startup reload gap without a diagnostic")
    func silentSynchronization() throws {
        let fixture = try TemporaryAppSettingsFixture()
        defer { fixture.cleanUp() }
        var events: [AppSettingsDiagnosticEvent] = []
        let store = AppSettingsStore(
            fileStore: fixture.store,
            diagnosticEventHandler: { events.append($0) },
            legacySnapshotProvider: { nil }
        )
        store.bootstrap()
        store.analytics.update { $0.consentLevel = .productUsage }
        try fixture.writeConfig("[analytics]\nconsent_level = \"off\"\n")

        store.synchronizeFromDisk()

        #expect(store.analytics.value.consentLevel == .off)
        #expect(events.isEmpty)
    }

    @Test("unreadable config fails effective consent closed")
    func unreadableConfigFailsClosed() throws {
        let fixture = try TemporaryAppSettingsFixture()
        defer { fixture.cleanUp() }
        let store = AppSettingsStore(
            fileStore: fixture.store,
            legacySnapshotProvider: { nil }
        )
        store.bootstrap()
        store.analytics.update { $0.consentLevel = .productUsage }
        try FileManager.default.removeItem(at: fixture.configURL)
        try FileManager.default.createDirectory(at: fixture.configURL, withIntermediateDirectories: false)

        store.synchronizeFromDisk()

        #expect(store.loadSource == .unreadableExistingFile)
        #expect(store.isDiskConfigInvalid)
        #expect(store.analytics.value.consentLevel == .productUsage)
    }

    @Test("failed reset after deletion emits a rejected outcome and fails closed")
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
        store.analytics.update { $0.consentLevel = .productUsage }
        #expect(store.analytics.value.consentLevel == .productUsage)
        try FileManager.default.removeItem(at: fixture.configURL)
        store.saveToDisk = { _ throws(ConfigFileStoreError) in
            throw .cannotWrite(fixture.configURL, message: "denied")
        }

        store.reloadFromDisk()

        #expect(events.last == .resetAfterDeletionRejected)
        #expect(store.latestError != nil)
        #expect(store.analytics.value.consentLevel == .off)
    }
}
