import Foundation
import Testing
@testable import AwesoMuxConfig

@Suite("ConfigFileStore")
struct ConfigFileStoreTests {
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
