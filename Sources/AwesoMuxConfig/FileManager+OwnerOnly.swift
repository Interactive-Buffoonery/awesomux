import Foundation

/// Owner-only posture for locally persisted state: directories are `0o700`,
/// files are `0o600`. Local stores (config, session snapshots, agent install
/// state) hold agent-permission posture and tool-trust-adjacent data, so
/// nothing they write should be readable by other local users — the default
/// macOS umask would leave directories at `0o755` and files at `0o644`.
/// New stores adopt these helpers instead of re-implementing the clamp
/// (INT-859).
extension FileManager {
    /// Creates `url` (and any missing intermediates) as an owner-only
    /// (`0o700`) directory. Like the underlying
    /// `createDirectory(withIntermediateDirectories: true)`, an existing
    /// directory is a no-op — it is not re-clamped; use
    /// `setOwnerOnlyPermissions(onDirectoryAt:)` for that.
    public func createOwnerOnlyDirectory(at url: URL) throws {
        try createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    /// Clamps an existing directory to owner-only (`0o700`).
    public func setOwnerOnlyPermissions(onDirectoryAt url: URL) throws {
        try setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    /// Clamps an existing file to owner-only (`0o600`).
    public func setOwnerOnlyPermissions(onFileAt url: URL) throws {
        try setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
