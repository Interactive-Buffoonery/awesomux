import Foundation
import Testing
@testable import AwesoMuxConfig

@Suite("ConfigFileStore")
struct ConfigFileStoreTests {
    private let codec = TOMLConfigCodec()

    @Test("missing config creates parent directory and config file")
    func missingConfigCreatesParentDirectoryAndConfigFile() throws {
        let fixture = try TemporaryConfigFixture()
        defer { fixture.cleanUp() }

        let result = try fixture.store.bootstrap()

        #expect(result.config == .defaultValue)
        #expect(result.source == .createdDefault)
        #expect(FileManager.default.fileExists(atPath: fixture.configDirectoryURL.path))
        #expect(FileManager.default.fileExists(atPath: fixture.configURL.path))
    }

    @Test("missing config writes default config when no legacy snapshot is provided")
    func missingConfigWritesDefaultConfigWhenNoLegacySnapshotIsProvided() throws {
        let fixture = try TemporaryConfigFixture()
        defer { fixture.cleanUp() }

        _ = try fixture.store.bootstrap()
        let decoded = try codec.decode(Data(contentsOf: fixture.configURL))

        #expect(decoded == .defaultValue)
    }

    @Test("missing config writes migrated config when legacy snapshot is provided")
    func missingConfigWritesMigratedConfigWhenLegacySnapshotIsProvided() throws {
        let fixture = try TemporaryConfigFixture()
        defer { fixture.cleanUp() }
        let snapshot = LegacySettingsSnapshot(
            theme: "mocha",
            accentColor: "sapphire",
            glowStrength: 0.25,
            notificationsMuted: true,
            notificationSoundEnabled: false,
            respectDoNotDisturb: false,
            rememberToolTrust: false,
            defaultWorkspaceGroup: "Clients",
            outputMarksNeedsAttention: false
        )

        let result = try fixture.store.bootstrap(legacySnapshot: snapshot)
        let decoded = try codec.decode(Data(contentsOf: fixture.configURL))

        #expect(result.source == .migratedLegacy)
        #expect(result.config == snapshot.migratedConfig())
        #expect(decoded == snapshot.migratedConfig())
    }

    @Test("existing valid config loads without rewriting the file")
    func existingValidConfigLoadsWithoutRewritingTheFile() throws {
        let fixture = try TemporaryConfigFixture()
        defer { fixture.cleanUp() }
        let config = AwesoMuxConfig(
            appearance: AppearanceConfig(theme: .dark, accent: .green, glowStrength: 0.1)
        )
        let toml = try codec.encodeString(config)
        try fixture.writeConfig(toml)

        let result = try fixture.store.bootstrap()
        let fileContents = try String(contentsOf: fixture.configURL, encoding: .utf8)

        #expect(result.config == config)
        #expect(result.source == .existingFile)
        #expect(fileContents == toml)
    }

    @Test("existing invalid config is preserved and returns a validation error")
    func existingInvalidConfigIsPreservedAndReturnsValidationError() throws {
        let fixture = try TemporaryConfigFixture()
        defer { fixture.cleanUp() }
        let invalidTOML = """
        [appearance]
        theme =
        """
        try fixture.writeConfig(invalidTOML)

        let result = try fixture.store.bootstrap()
        let fileContents = try String(contentsOf: fixture.configURL, encoding: .utf8)

        #expect(result.config == nil)
        #expect(result.source == .invalidExistingFile)
        #expect(result.error != nil)
        #expect(fileContents == invalidTOML)
    }

    @Test("load rejects a config not owned by the effective user")
    func loadRejectsConfigOwnedByAnotherUser() throws {
        let fixture = try TemporaryConfigFixture()
        defer { fixture.cleanUp() }
        try fixture.writeConfig("schema_version = 1")
        let store = ConfigFileStore(
            configURL: fixture.configURL,
            effectiveUID: geteuid() + 1
        )

        let result = store.load()

        #expect(result.source == .unreadableExistingFile)
        #expect(result.error == .unreadable(fixture.configURL))
    }

    @Test("bootstrap rejects oversized config without replacing it")
    func bootstrapRejectsOversizedConfigWithoutReplacingIt() throws {
        let fixture = try TemporaryConfigFixture()
        defer { fixture.cleanUp() }
        let oversized = Data(repeating: UInt8(ascii: "a"), count: 256 * 1024 + 1)
        try fixture.writeConfig(oversized)

        let result = try fixture.store.bootstrap()

        #expect(result.source == .invalidExistingFile)
        #expect(
            result.error
                == .invalidValue(
                    path: "$",
                    message: "Input exceeds maximum size of 262144 bytes"
                )
        )
        #expect(try Data(contentsOf: fixture.configURL).count == oversized.count)
    }

    @Test("load follows a symlink to an owned regular config")
    func loadFollowsSymlinkToOwnedRegularConfig() throws {
        let fixture = try TemporaryConfigFixture()
        defer { fixture.cleanUp() }
        try FileManager.default.createDirectory(
            at: fixture.configDirectoryURL,
            withIntermediateDirectories: true
        )
        let target = fixture.configDirectoryURL.appending(path: "managed.toml")
        try Data("schema_version = 1".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: fixture.configURL,
            withDestinationURL: target
        )

        let result = fixture.store.load()

        #expect(result.source == .existingFile)
        #expect(result.config != nil)
    }

    @Test("load rejects a symlink to a FIFO")
    func loadRejectsSymlinkToFIFO() throws {
        let fixture = try TemporaryConfigFixture()
        defer { fixture.cleanUp() }
        try FileManager.default.createDirectory(
            at: fixture.configDirectoryURL,
            withIntermediateDirectories: true
        )
        let fifo = fixture.configDirectoryURL.appending(path: "config.pipe")
        try #require(mkfifo(fifo.path, 0o600) == 0)
        try FileManager.default.createSymbolicLink(
            at: fixture.configURL,
            withDestinationURL: fifo
        )

        let result = fixture.store.load()

        #expect(result.source == .unreadableExistingFile)
        #expect(result.error == .notAFile(fixture.configURL))
    }

    @Test("save writes TOML that decodes back to the saved config")
    func saveWritesTOMLThatDecodesBackToSavedConfig() throws {
        let fixture = try TemporaryConfigFixture()
        defer { fixture.cleanUp() }
        let config = AwesoMuxConfig(
            notifications: NotificationConfig(muted: true, sound: false),
            workspaces: WorkspaceConfig(defaultGroup: "Support", outputMarksNeedsAttention: false)
        )

        try fixture.store.save(config)
        let decoded = try codec.decode(Data(contentsOf: fixture.configURL))

        #expect(decoded == config)
    }

    @Test("save replaces an existing config atomically enough for unit testing")
    func saveReplacesExistingConfigAtomicallyEnoughForUnitTesting() throws {
        let fixture = try TemporaryConfigFixture()
        defer { fixture.cleanUp() }
        try fixture.store.save(.defaultValue)
        let updated = AwesoMuxConfig(appearance: AppearanceConfig(theme: .light, accent: .mauve))

        try fixture.store.save(updated)
        let decoded = try codec.decode(Data(contentsOf: fixture.configURL))
        let siblingNames = try FileManager.default.contentsOfDirectory(atPath: fixture.configDirectoryURL.path)

        #expect(decoded == updated)
        #expect(!siblingNames.contains { $0.hasSuffix(".tmp") })
    }

    @Test("path resolution can be pointed at a temp directory")
    func pathResolutionCanBePointedAtTempDirectory() throws {
        let fixture = try TemporaryConfigFixture()
        defer { fixture.cleanUp() }
        let resolver = ConfigPathResolver(homeDirectory: fixture.homeURL)

        #expect(resolver.configDirectoryURL == fixture.configDirectoryURL)
        #expect(resolver.configFileURL == fixture.configURL)
    }

    @Test("migration maps every legacy key")
    func migrationMapsEveryLegacyKey() {
        let snapshot = LegacySettingsSnapshot(
            theme: "latte",
            accentColor: "mauve",
            glowStrength: 0.33,
            notificationsMuted: true,
            notificationSoundEnabled: false,
            respectDoNotDisturb: false,
            rememberToolTrust: false,
            defaultWorkspaceGroup: "Field Ops",
            outputMarksNeedsAttention: false
        )

        let config = snapshot.migratedConfig()

        #expect(config.appearance.theme == .light)
        #expect(config.appearance.accent == .mauve)
        #expect(config.appearance.glowStrength == 0.33)
        #expect(config.notifications.muted)
        #expect(!config.notifications.sound)
        #expect(!config.notifications.respectDoNotDisturb)
        #expect(!config.agents.rememberToolTrust)
        #expect(config.workspaces.defaultGroup == "Field Ops")
        #expect(!config.workspaces.outputMarksNeedsAttention)
    }

    @Test("migration handles absent legacy values by falling back to defaults")
    func migrationHandlesAbsentLegacyValuesByFallingBackToDefaults() {
        let config = LegacySettingsSnapshot().migratedConfig()

        #expect(config == .defaultValue)
    }

    @Test("persisted legacy snapshot ignores registered defaults")
    func persistedLegacySnapshotIgnoresRegisteredDefaults() throws {
        let suiteName = "awesomux-config-registered-defaults-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.register(defaults: [
            "settings.theme": "latte",
            "settings.notificationsMuted": true
        ])

        let snapshot = LegacySettingsSnapshot(
            persistedUserDefaults: defaults,
            domainName: suiteName
        )

        #expect(snapshot == nil)
    }

    @Test("persisted legacy snapshot includes default-equivalent keys")
    func persistedLegacySnapshotIncludesDefaultEquivalentKeys() throws {
        let suiteName = "awesomux-config-persisted-defaults-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("system", forKey: "settings.theme")

        let snapshot = try #require(LegacySettingsSnapshot(
            persistedUserDefaults: defaults,
            domainName: suiteName
        ))

        #expect(snapshot.theme == "system")
    }

    @Test("save and load errors are surfaced through app-owned errors")
    func saveAndLoadErrorsAreSurfacedThroughAppOwnedErrors() throws {
        let loadFixture = try TemporaryConfigFixture()
        defer { loadFixture.cleanUp() }
        try FileManager.default.createDirectory(
            at: loadFixture.configURL,
            withIntermediateDirectories: true
        )

        let loadResult = loadFixture.store.load()
        // load() now distinguishes "is a directory" from "couldn't read"
        // and surfaces the more specific notAFile error.
        #expect(loadResult.error == .notAFile(loadFixture.configURL))

        let saveFixture = try TemporaryConfigFixture()
        defer { saveFixture.cleanUp() }
        try FileManager.default.createDirectory(
            at: saveFixture.homeURL,
            withIntermediateDirectories: true
        )
        let configParentCollisionURL = saveFixture.homeURL.appendingPathComponent(".config")
        try "not a directory".write(to: configParentCollisionURL, atomically: false, encoding: .utf8)

        do {
            try saveFixture.store.save(.defaultValue)
            Issue.record("Expected save to fail")
        } catch ConfigFileStoreError.cannotCreateDirectory(let url, let message) {
            #expect(url == saveFixture.configDirectoryURL)
            #expect(!message.isEmpty)
        } catch {
            Issue.record("Expected ConfigFileStoreError, got \(error)")
        }
    }
}

private struct TemporaryConfigFixture {
    let homeURL: URL
    let configDirectoryURL: URL
    let configURL: URL
    let store: ConfigFileStore

    init() throws {
        homeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("awesomux-config-tests-\(UUID().uuidString)", isDirectory: true)
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

    func writeConfig(_ data: Data) throws {
        try FileManager.default.createDirectory(
            at: configDirectoryURL,
            withIntermediateDirectories: true
        )
        try data.write(to: configURL)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: homeURL)
    }
}
