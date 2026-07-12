import Foundation

/// Snapshot of facts about the Ghostty config environment that awesoMux can
/// log at info level at startup. Records the awesoMux-default
/// `scrollback-limit` and whether the two user-config directories libghostty
/// auto-loads contain a supported config filename. Existence is logged as bools
/// only — the paths themselves are PII-adjacent (they embed `$HOME`).
///
/// libghostty calls `ghostty_config_load_default_files` after awesoMux's
/// bundled defaults, so an existing user config can override
/// `scrollback-limit`. This snapshot tells a future debugger which side
/// of that override their capture is on without requiring DEBUG-only
/// diagnostics.
public struct GhosttyConfigEnvironment: Equatable, Sendable {
    private static let supportedConfigFilenames = ["config.ghostty", "config"]

    public let defaultScrollbackLimitBytes: Int
    public let userXDGConfigExists: Bool
    public let userAppSupportConfigExists: Bool

    public init(
        defaultScrollbackLimitBytes: Int,
        userXDGConfigExists: Bool,
        userAppSupportConfigExists: Bool
    ) {
        self.defaultScrollbackLimitBytes = defaultScrollbackLimitBytes
        self.userXDGConfigExists = userXDGConfigExists
        self.userAppSupportConfigExists = userAppSupportConfigExists
    }

    /// Pure snapshot factory. Injected `homeDirectory`, `xdgConfigHome`,
    /// and `environment` keep the snapshot testable without mutating the
    /// process environment. When called with no arguments, reads `$HOME`
    /// and `$XDG_CONFIG_HOME` from the process environment.
    public static func snapshot(
        homeDirectory: URL? = nil,
        xdgConfigHome: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> GhosttyConfigEnvironment {
        let resolvedHome = resolveHomeDirectory(
            override: homeDirectory,
            environment: environment
        )
        let resolvedXDG = resolveXDGConfigHome(
            override: xdgConfigHome,
            environment: environment,
            home: resolvedHome
        )

        let xdgConfigDirectory = resolvedXDG
            .appendingPathComponent("ghostty", isDirectory: true)
        let appSupportConfigDirectory = resolvedHome
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("com.mitchellh.ghostty", isDirectory: true)

        return GhosttyConfigEnvironment(
            defaultScrollbackLimitBytes: GhosttyRuntimeDefaults.scrollbackLimit,
            userXDGConfigExists: configExists(in: xdgConfigDirectory, fileManager: fileManager),
            userAppSupportConfigExists: configExists(in: appSupportConfigDirectory, fileManager: fileManager)
        )
    }

    /// Resolves the effective `$HOME` directory, honoring an explicit
    /// override, then the `HOME` env var (treating empty-string as unset),
    /// then falling back to Foundation's home-directory lookup.
    static func resolveHomeDirectory(
        override: URL?,
        environment: [String: String]
    ) -> URL {
        if let override { return override }
        if let env = environment["HOME"], !env.isEmpty {
            return URL(fileURLWithPath: env, isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    /// Resolves the effective `$XDG_CONFIG_HOME` directory, honoring an
    /// explicit override, then the `XDG_CONFIG_HOME` env var (treating
    /// empty-string as unset), then falling back to `$HOME/.config`.
    /// Extracted so the empty-string env-var branch is reachable in tests.
    static func resolveXDGConfigHome(
        override: URL?,
        environment: [String: String],
        home: URL
    ) -> URL {
        if let override { return override }
        if let env = environment["XDG_CONFIG_HOME"], !env.isEmpty {
            return URL(fileURLWithPath: env, isDirectory: true)
        }
        return home.appendingPathComponent(".config", isDirectory: true)
    }

    private static func configExists(in directory: URL, fileManager: FileManager) -> Bool {
        supportedConfigFilenames.contains { filename in
            fileManager.fileExists(
                atPath: directory.appendingPathComponent(filename, isDirectory: false).path
            )
        }
    }

    /// Single-line log payload for the unified log. Fields are scalar
    /// bools and ints, safe to emit at `privacy: .public`.
    public var logFields: String {
        [
            "default_scrollback_limit_bytes=\(defaultScrollbackLimitBytes)",
            "user_xdg_config_exists=\(userXDGConfigExists)",
            "user_app_support_config_exists=\(userAppSupportConfigExists)"
        ].joined(separator: " ")
    }
}
