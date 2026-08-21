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

    /// Returns `url` only once it is a real owner-only directory, optionally
    /// creating it first.
    ///
    /// The order is load-bearing, so app-support caches share this one
    /// implementation rather than each re-deriving it. The symlink check runs
    /// BEFORE the create so a pre-planted link is never followed into a
    /// directory this process does not own, and again AFTER — paired with an
    /// `isDirectory` assertion — because the path can be swapped in between.
    /// The trailing clamp is not redundant with the create: as documented on
    /// `createOwnerOnlyDirectory`, an existing directory is a no-op, so a cache
    /// left at `0o755` by an older build or by the user would otherwise stay
    /// group- and world-readable forever.
    ///
    /// A `createIfMissing: false` caller does not re-clamp — a read-only caller
    /// has no business widening or narrowing a directory it did not make — so it
    /// instead *refuses* a directory that is group- or world-WRITABLE. That is
    /// the bit that matters: a writable cache root lets another local user
    /// steer the prune into deleting files it did not choose, and lets them
    /// plant a symlink at a slot name before this process writes it.
    ///
    /// The readable bits are deliberately tolerated here. Every file inside is
    /// `0o600` and every slot name is a 128-bit SHA-256 prefix, so a readable
    /// directory discloses nothing the file mode does not already withhold —
    /// while refusing it stops the PRUNE as well as the read, leaving stale
    /// plaintext transcripts on disk for longer. Refusing on readability costs
    /// the very thing it claims to protect, and it is self-healing anyway: the
    /// next `createIfMissing: true` write re-clamps to `0o700`. An upgrading
    /// user whose cache predates the clamp keeps a working prune.
    ///
    /// - Returns: `url`, or `nil` if any check failed. `nil` means "do not read
    ///   or write here" — never "retry unchecked".
    public func validatedOwnerOnlyDirectory(at url: URL, createIfMissing: Bool) -> URL? {
        if (try? destinationOfSymbolicLink(atPath: url.path)) != nil {
            return nil
        }
        if !fileExists(atPath: url.path) {
            guard createIfMissing else { return nil }
            do {
                try createOwnerOnlyDirectory(at: url)
            } catch {
                return nil
            }
        }
        guard (try? destinationOfSymbolicLink(atPath: url.path)) == nil,
            ((try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory) == true
        else {
            return nil
        }
        if createIfMissing {
            do {
                try setOwnerOnlyPermissions(onDirectoryAt: url)
            } catch {
                return nil
            }
        } else {
            guard
                let mode = (try? attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber,
                mode.intValue & 0o022 == 0
            else {
                return nil
            }
        }
        return url
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
