import Darwin
import Foundation

/// Owner-only posture for locally persisted state: directories are `0o700`,
/// files are `0o600`. Local stores (config, session snapshots, agent install
/// state) hold agent-permission posture and tool-trust-adjacent data, so
/// nothing they write should be readable by other local users — the default
/// macOS umask would leave directories at `0o755` and files at `0o644`.
/// New stores adopt these helpers instead of re-implementing the clamp,
/// and whole-file writes go through `writeOwnerOnlyFile(at:contents:)` so
/// bytes never sit at umask-default permissions (INT-859).
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
    ///
    /// Follows symlinks: callers must only pass paths they just wrote
    /// atomically (which replaces any pre-planted link). A caller without
    /// that guarantee would chmod through a link to an unrelated target.
    public func setOwnerOnlyPermissions(onFileAt url: URL) throws {
        try setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Atomically writes `contents` to `url` with the file at exactly `0o600`
    /// before any bytes land, closing the window a write-then-chmod shape
    /// leaves open. The parent directory must already exist.
    public func writeOwnerOnlyFile(at url: URL, contents: Data) throws {
        let temporaryURL = url.deletingLastPathComponent()
            .appending(path: ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        var shouldRemoveTempFile = true
        defer {
            if shouldRemoveTempFile { try? removeItem(at: temporaryURL) }
        }

        let descriptor = Darwin.open(
            temporaryURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
            0o600
        )
        guard descriptor >= 0 else {
            let savedErrno = errno
            throw POSIXError(POSIXErrorCode(rawValue: savedErrno) ?? .EIO)
        }
        guard fchmod(descriptor, 0o600) == 0 else {
            let savedErrno = errno
            close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: savedErrno) ?? .EIO)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: contents)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }

        guard Darwin.rename(temporaryURL.path, url.path) == 0 else {
            let savedErrno = errno
            throw POSIXError(POSIXErrorCode(rawValue: savedErrno) ?? .EIO)
        }
        shouldRemoveTempFile = false
    }
}
