import Foundation

enum PrivateFilePermissions {
    private static let directoryMode = 0o700
    private static let fileMode = 0o600

    static func createDirectory(
        at url: URL,
        fileManager: FileManager = .default
    ) throws {
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: directoryMode]
        )
        try set(directoryMode, on: url, fileManager: fileManager)
    }

    /// Follows symlinks: callers must only pass paths they just wrote
    /// atomically (which replaces any pre-planted link). A caller without
    /// that guarantee would chmod through a link to an unrelated target.
    static func secureFile(
        at url: URL,
        fileManager: FileManager = .default
    ) throws {
        try set(fileMode, on: url, fileManager: fileManager)
    }

    private static func set(
        _ mode: Int,
        on url: URL,
        fileManager: FileManager
    ) throws {
        try fileManager.setAttributes(
            [.posixPermissions: mode],
            ofItemAtPath: url.path
        )
    }
}
