import Foundation
import Testing
@testable import AwesoMuxConfig

/// Owner-only permissions, symlink write-through, typed hostile decode, and
/// the encode size cap.
@Suite("PR92 review fixes")
struct PR92ReviewTests {
    private let codec = TOMLConfigCodec()

    @Test("directory at the config path surfaces notAFile, not unreadable")
    func directoryAtConfigPathSurfacesNotAFile() throws {
        let fixture = try TemporaryConfigFixture()
        defer { fixture.cleanUp() }

        try FileManager.default.createDirectory(
            at: fixture.configURL,
            withIntermediateDirectories: true
        )

        let result = fixture.store.load()
        #expect(result.source == .unreadableExistingFile)
        #expect(result.error == .notAFile(fixture.configURL))
        #expect(result.error?.displayText.contains("directory or special file") == true)
    }

    @Test("save writes through a symlinked config file to its target")
    func saveWritesThroughSymlinkedConfig() throws {
        let fixture = try TemporaryConfigFixture()
        defer { fixture.cleanUp() }

        // Create the config directory and a target file in a sibling
        // directory; the configURL is a symlink to the target.
        try FileManager.default.createDirectory(
            at: fixture.configDirectoryURL,
            withIntermediateDirectories: true
        )
        let targetURL = fixture.homeURL.appendingPathComponent("dotfiles-target.toml")
        try Data("placeholder = true\n".utf8).write(to: targetURL)
        try FileManager.default.createSymbolicLink(
            at: fixture.configURL,
            withDestinationURL: targetURL
        )

        try fixture.store.save(.defaultValue)

        // The symlink should still be a symlink (not replaced with a
        // regular file), and the target should contain our config.
        let attrs = try FileManager.default.attributesOfItem(atPath: fixture.configURL.path)
        // attributesOfItem follows symlinks — to check the symlink
        // itself, use destinationOfSymbolicLink, which throws on a
        // regular file.
        let dest = try FileManager.default.destinationOfSymbolicLink(atPath: fixture.configURL.path)
        #expect(dest.contains("dotfiles-target"))
        _ = attrs

        let targetBytes = try Data(contentsOf: targetURL)
        let decoded = try codec.decode(targetBytes)
        #expect(decoded.appearance.theme == AwesoMuxConfig.defaultValue.appearance.theme)
    }

    @Test("first save creates config file with 0o600 permissions")
    func firstSaveSetsOwnerOnlyPermissions() throws {
        let fixture = try TemporaryConfigFixture()
        defer { fixture.cleanUp() }

        try fixture.store.save(.defaultValue)

        let attrs = try FileManager.default.attributesOfItem(atPath: fixture.configURL.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        #expect(perms == 0o600)
    }

    @Test("save clamps an existing world-readable config back to owner-only")
    func saveClampsExistingLaxPermissions() throws {
        let fixture = try TemporaryConfigFixture()
        defer { fixture.cleanUp() }

        // First save lands the file at 0o600. Widen it the way a dotfiles tool
        // or a stray chmod might, then save again: the replace path must clamp
        // group/other access off rather than faithfully preserving 0o644.
        try fixture.store.save(.defaultValue)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: fixture.configURL.path
        )

        try fixture.store.save(.defaultValue)

        let attrs = try FileManager.default.attributesOfItem(atPath: fixture.configURL.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
        #expect(perms & 0o077 == 0)      // no group/other access survives
        #expect(perms & 0o600 == 0o600)  // owner read/write retained
    }

    @Test("created config directory has 0o700 permissions")
    func createdConfigDirectoryIsOwnerOnly() throws {
        let fixture = try TemporaryConfigFixture()
        defer { fixture.cleanUp() }

        try fixture.store.save(.defaultValue)

        let attrs = try FileManager.default.attributesOfItem(atPath: fixture.configDirectoryURL.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        #expect(perms == 0o700)
    }

    @Test("present-but-wrong-type string field throws instead of silently defaulting")
    func workspacesStringFieldWrongTypeThrows() {
        // A present key with the wrong type must still surface a loud error —
        // the deliberate posture INT-369 preserves over silent defaulting.
        // Assert the codec's typed error rather than `any Error` so the test
        // can't pass green for an unrelated failure.
        let source = """
        [workspaces]
        default_group = 123
        """

        #expect(throws: ConfigLoadError.self) {
            _ = try codec.decode(source)
        }
    }

    @Test("present-but-wrong-type bool field throws instead of silently defaulting")
    func workspacesBoolFieldWrongTypeThrows() {
        // The Bool fields decode through a different branch than default_group;
        // `confirm_destructive_pane_action_with_running_agent = "yes"` is the
        // realistic hand-edit mistake (TOML users quoting a bool). It must
        // throw, not default.
        let source = """
        [workspaces]
        confirm_destructive_pane_action_with_running_agent = "yes"
        """

        #expect(throws: ConfigLoadError.self) {
            _ = try codec.decode(source)
        }
    }

    @Test("encode rejects a config that exceeds the size cap")
    func encodeRejectsOversizeConfig() throws {
        // Stuff the unknown-tables catch-all with a giant fragment.
        let bigFragment = String(repeating: "x", count: 270_000)
        let oversized = AwesoMuxConfig(
            unknownTopLevelTables: ["huge": "data = \"\(bigFragment)\""]
        )

        do {
            _ = try codec.encode(oversized)
            Issue.record("Expected encode to throw size error")
        } catch {
            guard case let .invalidValue(_, message) = error else {
                Issue.record("Expected invalidValue, got \(error)")
                return
            }
            #expect(message.contains("maximum size"))
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
            .appendingPathComponent("awesomux-pr92-tests-\(UUID().uuidString)", isDirectory: true)
        let resolver = ConfigPathResolver(homeDirectory: homeURL)
        configDirectoryURL = resolver.configDirectoryURL
        configURL = resolver.configFileURL
        store = ConfigFileStore(pathResolver: resolver)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: homeURL)
    }
}
