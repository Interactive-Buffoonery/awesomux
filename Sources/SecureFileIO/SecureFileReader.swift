import Darwin
import Foundation

// MARK: - Errors and results

public enum SecureFileReadError: Error, Equatable, Sendable {
    case unreadable
    case notRegularFile
    case wrongOwner
    case tooLarge
}

/// Controls whether a caller deliberately accepts a symlink at the final path
/// component. Intermediate path components are resolved once and then opened
/// without following any later replacements.
public enum SecureFileSymlinkPolicy: Sendable {
    case resolve
    case rejectFinalComponent
}

public struct SecureFileContents: Equatable, Sendable {
    public let resolvedURL: URL
    public let identity: SecureFileIdentity
    public let data: Data
}

public struct SecureFileIdentity: Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64
}

// MARK: - Validated handle

public final class SecureFileReadHandle: @unchecked Sendable {
    public let resolvedURL: URL
    public let identity: SecureFileIdentity
    public let size: UInt64
    private let descriptor: Int32

    fileprivate init(
        resolvedURL: URL,
        identity: SecureFileIdentity,
        size: UInt64,
        descriptor: Int32
    ) {
        self.resolvedURL = resolvedURL
        self.identity = identity
        self.size = size
        self.descriptor = descriptor
    }

    deinit {
        close(descriptor)
    }

    /// Reads from offset zero without reopening the path. A one-byte probe after
    /// the cap catches growth that happened after the descriptor's initial `fstat`.
    public func read(maximumBytes: Int) throws(SecureFileReadError) -> Data {
        guard maximumBytes >= 0 else {
            throw .unreadable
        }
        return try SecureFileReader.readBounded(
            from: descriptor,
            maximumBytes: maximumBytes
        )
    }

    /// Reads up to `maximumBytes` from offset zero and stops there.
    ///
    /// The difference from `read(maximumBytes:)` is what a longer file means.
    /// There, the cap is a limit the file must respect and exceeding it is
    /// `.tooLarge`; here, the cap is a window the caller deliberately chose and
    /// more bytes past it are the expected case.
    public func readPrefix(maximumBytes: Int) throws(SecureFileReadError) -> Data {
        guard maximumBytes >= 0 else {
            throw .unreadable
        }
        return try SecureFileReader.readBounded(
            from: descriptor,
            maximumBytes: maximumBytes,
            rejectingOverflow: false
        )
    }

    /// Reads up to `maximumBytes` from the END of the file.
    ///
    /// The mirror of `readPrefix(maximumBytes:)`. Both treat the cap as a window
    /// the caller chose rather than a limit the file must respect, so a longer
    /// file is the expected case, not `.tooLarge`.
    ///
    /// The window is anchored to the SMALLER of the size captured at `open` and
    /// the file's length right now. Bytes appended after `open` are still not
    /// read — the validated size is the only length this handle can vouch for —
    /// but a file that shrank is followed down, because the stale size would
    /// otherwise put the whole window past EOF and return nothing at all.
    ///
    /// - Returns: The bytes read, the offset they were read from, and the byte
    ///   immediately before that offset (`nil` at offset zero).
    ///
    ///   `startOffset > 0` is the only sound test for "earlier bytes were
    ///   skipped": inferring it by comparing `size` against the returned count
    ///   is wrong whenever the file was truncated between `open` and this read,
    ///   which returns short from offset zero with nothing skipped at all.
    ///
    ///   `precedingByte` is what a line-oriented caller needs to separate "the
    ///   window landed mid-record" from "the window landed exactly on a record
    ///   separator". The reader hands the byte over rather than interpreting
    ///   it, so nothing about record framing lives in here.
    public func readSuffix(
        maximumBytes: Int
    ) throws(SecureFileReadError) -> (data: Data, startOffset: UInt64, precedingByte: UInt8?) {
        guard maximumBytes >= 0 else {
            throw .unreadable
        }
        let anchor = min(size, currentSize())
        let start = anchor > UInt64(maximumBytes) ? anchor - UInt64(maximumBytes) : 0
        guard start <= UInt64(off_t.max) else {
            throw .unreadable
        }
        let data = try SecureFileReader.readBounded(
            from: descriptor,
            maximumBytes: maximumBytes,
            startingAt: off_t(start),
            rejectingOverflow: false
        )
        return (data, start, start == 0 ? nil : byte(at: off_t(start) - 1))
    }

    /// The file's length as of now. Falls back to the size validated at `open`
    /// when `fstat` fails, so a failed probe leaves the window where it already
    /// was rather than collapsing it to zero.
    private func currentSize() -> UInt64 {
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_size >= 0 else { return size }
        return UInt64(status.st_size)
    }

    private func byte(at offset: off_t) -> UInt8? {
        var value: UInt8 = 0
        while true {
            let bytesRead = pread(descriptor, &value, 1, offset)
            if bytesRead < 0, errno == EINTR { continue }
            return bytesRead == 1 ? value : nil
        }
    }

    package var isCloseOnExec: Bool {
        Self.isCloseOnExec(descriptor: descriptor)
    }

    package static func isCloseOnExec(
        descriptor: Int32,
        getDescriptorFlags: (Int32) -> Int32 = { fcntl($0, F_GETFD) }
    ) -> Bool {
        let flags = getDescriptorFlags(descriptor)
        guard flags != -1 else { return false }
        return flags & FD_CLOEXEC != 0
    }
}

// MARK: - Reader

public enum SecureFileReader {
    /// Resolves deliberate symlinks, opens the resulting path once, validates the
    /// descriptor, and returns no more than `maximumBytes`.
    public static func read(
        at url: URL,
        maximumBytes: Int,
        effectiveUID: uid_t = geteuid(),
        symlinkPolicy: SecureFileSymlinkPolicy = .resolve
    ) throws(SecureFileReadError) -> SecureFileContents {
        do {
            return try read(
                at: url,
                maximumBytes: maximumBytes,
                effectiveUID: effectiveUID,
                symlinkPolicy: symlinkPolicy,
                afterOpen: {}
            )
        } catch let error as SecureFileReadError {
            throw error
        } catch {
            throw .unreadable
        }
    }

    /// Opens each resolved path component with `O_NOFOLLOW`, applies the
    /// caller's final-component symlink policy, then validates the descriptor
    /// as a regular file owned by `effectiveUID`.
    public static func open(
        at url: URL,
        effectiveUID: uid_t = geteuid(),
        symlinkPolicy: SecureFileSymlinkPolicy = .resolve
    ) throws(SecureFileReadError) -> SecureFileReadHandle {
        guard url.isFileURL else {
            throw .unreadable
        }

        do {
            let resolvedURL = try resolvedURL(for: url, symlinkPolicy: symlinkPolicy)
            let descriptor = try openWithoutFollowingSymlinks(at: resolvedURL)

            var status = stat()
            guard fstat(descriptor, &status) == 0 else {
                close(descriptor)
                throw SecureFileReadError.unreadable
            }
            guard (status.st_mode & S_IFMT) == S_IFREG else {
                close(descriptor)
                throw SecureFileReadError.notRegularFile
            }
            guard status.st_uid == effectiveUID else {
                close(descriptor)
                throw SecureFileReadError.wrongOwner
            }
            guard status.st_size >= 0 else {
                close(descriptor)
                throw SecureFileReadError.unreadable
            }

            return SecureFileReadHandle(
                resolvedURL: resolvedURL,
                identity: SecureFileIdentity(
                    device: UInt64(status.st_dev),
                    inode: UInt64(status.st_ino)
                ),
                size: UInt64(status.st_size),
                descriptor: descriptor
            )
        } catch let error as SecureFileReadError {
            throw error
        } catch {
            throw .unreadable
        }
    }

    package static func read(
        at url: URL,
        maximumBytes: Int,
        effectiveUID: uid_t = geteuid(),
        symlinkPolicy: SecureFileSymlinkPolicy = .resolve,
        afterOpen: () throws -> Void
    ) throws -> SecureFileContents {
        guard url.isFileURL, maximumBytes >= 0 else {
            throw SecureFileReadError.unreadable
        }

        let handle = try open(
            at: url,
            effectiveUID: effectiveUID,
            symlinkPolicy: symlinkPolicy
        )
        guard handle.size <= UInt64(maximumBytes) else {
            throw SecureFileReadError.tooLarge
        }

        try afterOpen()
        let data = try handle.read(maximumBytes: maximumBytes)
        return SecureFileContents(
            resolvedURL: handle.resolvedURL,
            identity: handle.identity,
            data: data
        )
    }

    // MARK: Path opening

    private static func resolvedURL(
        for url: URL,
        symlinkPolicy: SecureFileSymlinkPolicy
    ) throws -> URL {
        let pathToResolve: String
        let finalComponent: String?
        switch symlinkPolicy {
        case .resolve:
            pathToResolve = url.path
            finalComponent = nil
        case .rejectFinalComponent:
            pathToResolve = url.deletingLastPathComponent().path
            finalComponent = url.lastPathComponent
        }

        guard let resolvedPath = realpath(pathToResolve, nil) else {
            throw SecureFileReadError.unreadable
        }
        defer { free(resolvedPath) }
        let resolvedURL = URL(fileURLWithPath: String(cString: resolvedPath))
        guard let finalComponent else {
            return resolvedURL
        }
        return resolvedURL.appending(path: finalComponent)
    }

    private static func openWithoutFollowingSymlinks(at url: URL) throws -> Int32 {
        let components = url.pathComponents.dropFirst()
        guard let fileName = components.last else {
            throw SecureFileReadError.notRegularFile
        }

        var directoryDescriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directoryDescriptor >= 0 else {
            throw SecureFileReadError.unreadable
        }
        defer { close(directoryDescriptor) }

        for component in components.dropLast() {
            let nextDescriptor = component.withCString {
                Darwin.openat(
                    directoryDescriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard nextDescriptor >= 0 else {
                throw SecureFileReadError.unreadable
            }
            close(directoryDescriptor)
            directoryDescriptor = nextDescriptor
        }

        let fileDescriptor = fileName.withCString {
            Darwin.openat(
                directoryDescriptor,
                $0,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard fileDescriptor >= 0 else {
            throw SecureFileReadError.unreadable
        }
        return fileDescriptor
    }

    // MARK: Bounded reads

    fileprivate static func readBounded(
        from descriptor: Int32,
        maximumBytes: Int,
        startingAt startOffset: off_t = 0,
        rejectingOverflow: Bool = true
    ) throws(SecureFileReadError) -> Data {
        var result = Data()
        var offset = startOffset

        while result.count < maximumBytes {
            let chunkSize = min(64 * 1024, maximumBytes - result.count)
            var buffer = [UInt8](repeating: 0, count: chunkSize)
            let bytesRead = buffer.withUnsafeMutableBytes {
                pread(descriptor, $0.baseAddress, chunkSize, offset)
            }

            if bytesRead < 0 {
                if errno == EINTR {
                    continue
                }
                throw .unreadable
            }
            if bytesRead == 0 {
                return result
            }
            result.append(contentsOf: buffer.prefix(bytesRead))
            offset += off_t(bytesRead)
        }

        guard rejectingOverflow else { return result }

        var extraByte: UInt8 = 0
        while true {
            let bytesRead = pread(descriptor, &extraByte, 1, offset)
            if bytesRead < 0, errno == EINTR {
                continue
            }
            if bytesRead < 0 {
                throw .unreadable
            }
            if bytesRead > 0 {
                throw .tooLarge
            }
            return result
        }
    }
}
