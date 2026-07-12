import Foundation

public struct ConfigPathResolver: Equatable, Sendable {
    public var homeDirectory: URL
    public var configDirectoryName: String

    /// Production-pinned resolver (`~/.config/awesomux`). App-target callers
    /// must inject the active profile's directory name instead (see
    /// `AppRuntimeProfile.configDirectoryName`) — this module can't see the
    /// profile type, so this default can't be profile-aware.
    public static let `default` = ConfigPathResolver(
        homeDirectory: FileManager.default.homeDirectoryForCurrentUser
    )

    public init(homeDirectory: URL, configDirectoryName: String = "awesomux") {
        self.homeDirectory = homeDirectory
        self.configDirectoryName = configDirectoryName
    }

    public var configDirectoryURL: URL {
        homeDirectory
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent(configDirectoryName, isDirectory: true)
    }

    public var configFileURL: URL {
        configDirectoryURL.appendingPathComponent("config.toml", isDirectory: false)
    }
}
