import AwesoMuxTestSupport
import Foundation
import Testing
@testable import AwesoMuxConfig

@Suite("GhosttyConfigEnvironment")
struct GhosttyConfigEnvironmentTests {
    @Test("snapshot reports both user-config paths as missing in an empty home")
    func snapshotEmptyHomeReportsBothMissing() throws {
        let fixture = try TemporaryHomeFixture()
        defer { withExtendedLifetime(fixture) {} }

        let env = GhosttyConfigEnvironment.snapshot(
            homeDirectory: fixture.homeURL,
            xdgConfigHome: nil,
            environment: [:],
            fileManager: .default
        )

        #expect(env.defaultScrollbackLimitBytes == GhosttyRuntimeDefaults.scrollbackLimit)
        #expect(env.userXDGConfigExists == false)
        #expect(env.userAppSupportConfigExists == false)
    }

    @Test("snapshot detects ~/.config/ghostty/config.ghostty when XDG_CONFIG_HOME unset")
    func snapshotDetectsModernXDGConfigUnderDefaultPath() throws {
        let fixture = try TemporaryHomeFixture()
        defer { withExtendedLifetime(fixture) {} }
        try fixture.writeFile(
            relativePath: ".config/ghostty/config.ghostty",
            contents: "scrollback-limit = 99\n"
        )

        let env = GhosttyConfigEnvironment.snapshot(
            homeDirectory: fixture.homeURL,
            xdgConfigHome: nil,
            environment: [:],
            fileManager: .default
        )

        #expect(env.userXDGConfigExists == true)
        #expect(env.userAppSupportConfigExists == false)
    }

    @Test("snapshot detects legacy ~/.config/ghostty/config when XDG_CONFIG_HOME unset")
    func snapshotDetectsLegacyXDGConfigUnderDefaultPath() throws {
        let fixture = try TemporaryHomeFixture()
        defer { withExtendedLifetime(fixture) {} }
        try fixture.writeFile(
            relativePath: ".config/ghostty/config",
            contents: "scrollback-limit = 99\n"
        )

        let env = GhosttyConfigEnvironment.snapshot(
            homeDirectory: fixture.homeURL,
            xdgConfigHome: nil,
            environment: [:],
            fileManager: .default
        )

        #expect(env.userXDGConfigExists == true)
        #expect(env.userAppSupportConfigExists == false)
    }

    @Test("snapshot honors an explicit XDG_CONFIG_HOME override")
    func snapshotHonorsXDGOverride() throws {
        let fixture = try TemporaryHomeFixture()
        defer { withExtendedLifetime(fixture) {} }
        // Write configs under HOME/.config and the environment path, but pass
        // an explicit override that does NOT have one. Only the override
        // should determine the bool.
        try fixture.writeFile(
            relativePath: ".config/ghostty/config",
            contents: "ignored\n"
        )
        let siblingXDG = fixture.homeURL.appendingPathComponent("custom-xdg", isDirectory: true)
        try FileManager.default.createDirectory(at: siblingXDG, withIntermediateDirectories: true)
        let envXDG = fixture.homeURL.appendingPathComponent("env-xdg", isDirectory: true)
        try FileManager.default.createDirectory(at: envXDG, withIntermediateDirectories: true)
        try fixture.writeFile(
            relativePath: "env-xdg/ghostty/config.ghostty",
            contents: "ignored-env\n"
        )

        let env = GhosttyConfigEnvironment.snapshot(
            homeDirectory: fixture.homeURL,
            xdgConfigHome: siblingXDG,
            environment: ["XDG_CONFIG_HOME": envXDG.path],
            fileManager: .default
        )

        #expect(env.userXDGConfigExists == false)
    }

    @Test("snapshot detects ~/Library/Application Support/com.mitchellh.ghostty/config.ghostty")
    func snapshotDetectsModernAppSupportConfig() throws {
        let fixture = try TemporaryHomeFixture()
        defer { withExtendedLifetime(fixture) {} }
        try fixture.writeFile(
            relativePath: "Library/Application Support/com.mitchellh.ghostty/config.ghostty",
            contents: "scrollback-limit = 42\n"
        )

        let env = GhosttyConfigEnvironment.snapshot(
            homeDirectory: fixture.homeURL,
            xdgConfigHome: nil,
            environment: [:],
            fileManager: .default
        )

        #expect(env.userAppSupportConfigExists == true)
    }

    @Test("snapshot detects legacy ~/Library/Application Support/com.mitchellh.ghostty/config")
    func snapshotDetectsLegacyAppSupportConfig() throws {
        let fixture = try TemporaryHomeFixture()
        defer { withExtendedLifetime(fixture) {} }
        try fixture.writeFile(
            relativePath: "Library/Application Support/com.mitchellh.ghostty/config",
            contents: "scrollback-limit = 42\n"
        )

        let env = GhosttyConfigEnvironment.snapshot(
            homeDirectory: fixture.homeURL,
            xdgConfigHome: nil,
            environment: [:],
            fileManager: .default
        )

        #expect(env.userAppSupportConfigExists == true)
    }

    @Test("snapshot treats XDG_CONFIG_HOME=\"\" as unset and falls back to ~/.config")
    func snapshotEmptyXDGFallsBackToDefault() throws {
        let fixture = try TemporaryHomeFixture()
        defer { withExtendedLifetime(fixture) {} }
        try fixture.writeFile(
            relativePath: ".config/ghostty/config",
            contents: "fallback\n"
        )

        let env = GhosttyConfigEnvironment.snapshot(
            homeDirectory: fixture.homeURL,
            xdgConfigHome: nil,
            environment: ["XDG_CONFIG_HOME": ""],
            fileManager: .default
        )

        // Empty XDG_CONFIG_HOME must NOT be treated as a valid path
        // (URL(fileURLWithPath: "") resolves to the cwd, which would
        // give the wrong existence answer). Code falls back to
        // home/.config and finds the config we wrote.
        #expect(env.userXDGConfigExists == true)
    }

    @Test("snapshot uses HOME from the injected environment when no home override is passed")
    func snapshotUsesInjectedHomeEnvironment() throws {
        let fixture = try TemporaryHomeFixture()
        defer { withExtendedLifetime(fixture) {} }
        try fixture.writeFile(
            relativePath: ".config/ghostty/config.ghostty",
            contents: "home-env\n"
        )

        let env = GhosttyConfigEnvironment.snapshot(
            homeDirectory: nil,
            xdgConfigHome: nil,
            environment: ["HOME": fixture.homeURL.path],
            fileManager: .default
        )

        #expect(env.userXDGConfigExists == true)
        #expect(env.userAppSupportConfigExists == false)
    }

    @Test("snapshot honors a non-empty XDG_CONFIG_HOME env var when no override is passed")
    func snapshotHonorsXDGEnvVar() throws {
        let fixture = try TemporaryHomeFixture()
        defer { withExtendedLifetime(fixture) {} }
        let customXDG = fixture.homeURL.appendingPathComponent("custom-xdg", isDirectory: true)
        try FileManager.default.createDirectory(at: customXDG, withIntermediateDirectories: true)
        try fixture.writeFile(
            relativePath: ".config/ghostty/config",
            contents: "should-not-be-read\n"
        )
        try fixture.writeFile(
            relativePath: "custom-xdg/ghostty/config",
            contents: "read-this\n"
        )

        let env = GhosttyConfigEnvironment.snapshot(
            homeDirectory: fixture.homeURL,
            xdgConfigHome: nil,
            environment: ["XDG_CONFIG_HOME": customXDG.path],
            fileManager: .default
        )

        #expect(env.userXDGConfigExists == true)
    }

    @Test("resolveHomeDirectory contract: override beats env beats Foundation default")
    func resolveHomeDirectoryContract() {
        let override = URL(fileURLWithPath: "/tmp/override-home", isDirectory: true)

        let viaOverride = GhosttyConfigEnvironment.resolveHomeDirectory(
            override: override,
            environment: ["HOME": "/tmp/env-loser"]
        )
        #expect(viaOverride == override)

        let viaEnv = GhosttyConfigEnvironment.resolveHomeDirectory(
            override: nil,
            environment: ["HOME": "/tmp/env-winner"]
        )
        #expect(viaEnv == URL(fileURLWithPath: "/tmp/env-winner", isDirectory: true))

        let viaEnvEmpty = GhosttyConfigEnvironment.resolveHomeDirectory(
            override: nil,
            environment: ["HOME": ""]
        )
        #expect(viaEnvEmpty == URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true))
    }

    @Test("resolveXDGConfigHome contract: override beats env beats default")
    func resolveXDGConfigHomeContract() throws {
        let home = URL(fileURLWithPath: "/tmp/fake-home", isDirectory: true)
        let override = URL(fileURLWithPath: "/tmp/override", isDirectory: true)

        let viaOverride = GhosttyConfigEnvironment.resolveXDGConfigHome(
            override: override,
            environment: ["XDG_CONFIG_HOME": "/tmp/env-loser"],
            home: home
        )
        #expect(viaOverride == override)

        let viaEnv = GhosttyConfigEnvironment.resolveXDGConfigHome(
            override: nil,
            environment: ["XDG_CONFIG_HOME": "/tmp/env-winner"],
            home: home
        )
        #expect(viaEnv == URL(fileURLWithPath: "/tmp/env-winner", isDirectory: true))

        let viaEnvEmpty = GhosttyConfigEnvironment.resolveXDGConfigHome(
            override: nil,
            environment: ["XDG_CONFIG_HOME": ""],
            home: home
        )
        #expect(viaEnvEmpty == home.appendingPathComponent(".config", isDirectory: true))

        let viaDefault = GhosttyConfigEnvironment.resolveXDGConfigHome(
            override: nil,
            environment: [:],
            home: home
        )
        #expect(viaDefault == home.appendingPathComponent(".config", isDirectory: true))
    }

    @Test("logFields emits public-safe scalar values with no PII")
    func logFieldsContainsNoPII() {
        let env = GhosttyConfigEnvironment(
            defaultScrollbackLimitBytes: 5_000_000,
            userXDGConfigExists: true,
            userAppSupportConfigExists: false
        )

        let fields = env.logFields
        #expect(fields.contains("default_scrollback_limit_bytes=5000000"))
        #expect(fields.contains("user_xdg_config_exists=true"))
        #expect(fields.contains("user_app_support_config_exists=false"))
        #expect(fields.contains("/Users/") == false)
        #expect(fields.contains(NSUserName()) == false)
    }
}

private struct TemporaryHomeFixture {
    private let directory: TemporaryDirectory
    var homeURL: URL { directory.url }

    init() throws {
        directory = try TemporaryDirectory(prefix: "awesomux-int397")
    }

    func writeFile(relativePath: String, contents: String) throws {
        let target = homeURL.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: target, atomically: true, encoding: .utf8)
    }
}
