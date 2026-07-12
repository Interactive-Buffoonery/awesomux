import Darwin
import Foundation

// MARK: - Errors and results

public enum SecureFileReadError: Error, Equatable, Sendable {
    case unreadable
    case notRegularFile
    case wrongOwner
    case tooLarge
}

public struct SecureFileContents: Equatable, Sendable {
    public let resolvedURL: URL
    public let data: Data
}

// MARK: - Validated handle

public final class SecureFileReadHandle: @unchecked Sendable {
    public let resolvedURL: URL
    public let size: UInt64
    private let descriptor: Int32

    fileprivate init(resolvedURL: URL, size: UInt64, descriptor: Int32) {
        self.resolvedURL = resolvedURL
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
        effectiveUID: uid_t = geteuid()
    ) throws(SecureFileReadError) -> SecureFileContents {
        do {
            return try read(
                at: url,
                maximumBytes: maximumBytes,
                effectiveUID: effectiveUID,
                afterOpen: {}
            )
        } catch let error as SecureFileReadError {
            throw error
        } catch {
            throw .unreadable
        }
    }

    /// Opens each resolved path component with `O_NOFOLLOW`, then validates the
    /// final descriptor as a regular file owned by `effectiveUID`.
    public static func open(
        at url: URL,
        effectiveUID: uid_t = geteuid()
    ) throws(SecureFileReadError) -> SecureFileReadHandle {
        guard url.isFileURL else {
            throw .unreadable
        }

        do {
            let resolvedURL = try resolvedURL(for: url)
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
        afterOpen: () throws -> Void
    ) throws -> SecureFileContents {
        guard url.isFileURL, maximumBytes >= 0 else {
            throw SecureFileReadError.unreadable
        }

        let handle = try open(at: url, effectiveUID: effectiveUID)
        guard handle.size <= UInt64(maximumBytes) else {
            throw SecureFileReadError.tooLarge
        }

        try afterOpen()
        let data = try handle.read(maximumBytes: maximumBytes)
        return SecureFileContents(resolvedURL: handle.resolvedURL, data: data)
    }

    // MARK: Path opening

    private static func resolvedURL(for url: URL) throws -> URL {
        guard let resolvedPath = realpath(url.path, nil) else {
            throw SecureFileReadError.unreadable
        }
        defer { free(resolvedPath) }
        return URL(fileURLWithPath: String(cString: resolvedPath))
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
        maximumBytes: Int
    ) throws(SecureFileReadError) -> Data {
        var result = Data()
        var offset: off_t = 0

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
