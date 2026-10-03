import CryptoKit
import Darwin
import Foundation

/// This protects endpoint custody, not against other processes of the same user.
public final class LocalAPIEndpoint: @unchecked Sendable {
    public let profile: String
    public let directoryPath: String
    public var socketPath: String { directoryPath + "/api.sock" }
    private let directoryFD: Int32
    private var lockFD: Int32 = -1
    private var socketIdentity: (dev_t, ino_t)?

    public init(profile: String, create: Bool = false) throws {
        guard LocalAPIProfile.isValid(profile) else { throw LocalAPIError.profileMismatch }
        self.profile = profile
        let digest = SHA256.hash(data: Data(profile.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        directoryPath = "/private/tmp/awesomux-api-\(geteuid())-\(digest)"
        guard directoryPath.utf8.count + "/api.sock".utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path)
        else { throw LocalAPIError.pathTooLong }
        if create, mkdir(directoryPath, 0o700) != 0, errno != EEXIST { throw LocalAPIError.insecureEndpoint }
        let opened = open(directoryPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard opened >= 0 else {
            throw errno == ENOENT ? LocalAPIError.appUnavailable : LocalAPIError.insecureEndpoint
        }
        do { try Self.validateDirectory(fd: opened, path: directoryPath) } catch {
            close(opened)
            throw error
        }
        directoryFD = opened
    }

    deinit {
        if lockFD >= 0 { close(lockFD) }
        close(directoryFD)
    }

    func validateDirectory() throws {
        try Self.validateDirectory(fd: directoryFD, path: directoryPath)
    }

    private static func validateDirectory(fd: Int32, path: String) throws {
        var held = stat()
        var named = stat()
        guard fstat(fd, &held) == 0, lstat(path, &named) == 0,
            held.st_dev == named.st_dev, held.st_ino == named.st_ino,
            held.st_uid == geteuid(), held.st_mode & S_IFMT == S_IFDIR,
            held.st_mode & 0o777 == 0o700
        else { throw LocalAPIError.insecureEndpoint }
    }

    func takeOwnership() throws {
        try validateDirectory()
        lockFD = openat(directoryFD, "instance.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lockFD >= 0 else { throw LocalAPIError.insecureEndpoint }
        try validateLock()
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw LocalAPIError.endpointBusy }
        try validateDirectory()
        try validateLock()
        // Holding the live instance's lock is the stale proof; a PID is not.
        if try socketStat() != nil {
            guard unlinkat(directoryFD, "api.sock", 0) == 0 else { throw LocalAPIError.insecureEndpoint }
        }
    }

    private func validateLock() throws {
        var held = stat()
        var named = stat()
        guard fstat(lockFD, &held) == 0,
            fstatat(directoryFD, "instance.lock", &named, AT_SYMLINK_NOFOLLOW) == 0,
            held.st_dev == named.st_dev, held.st_ino == named.st_ino,
            held.st_uid == geteuid(), held.st_mode & S_IFMT == S_IFREG,
            held.st_mode & 0o777 == 0o600, held.st_nlink == 1
        else { throw LocalAPIError.insecureEndpoint }
    }

    private func socketStat() throws -> stat? {
        var info = stat()
        if fstatat(directoryFD, "api.sock", &info, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return nil }
            throw LocalAPIError.insecureEndpoint
        }
        guard info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFSOCK,
            info.st_mode & 0o777 == 0o600
        else { throw LocalAPIError.insecureEndpoint }
        return info
    }

    func recordSocket() throws {
        try validateDirectory()
        try validateLock()
        guard fchmodat(directoryFD, "api.sock", 0o600, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw LocalAPIError.insecureEndpoint
        }
        guard let info = try socketStat() else { throw LocalAPIError.insecureEndpoint }
        socketIdentity = (info.st_dev, info.st_ino)
    }

    func validateSocket() throws {
        try validateDirectory()
        guard try socketStat() != nil else { throw LocalAPIError.appUnavailable }
    }

    func cleanup() {
        // No cleanup if the name now identifies a successor's directory/socket.
        guard (try? validateDirectory()) != nil, (try? validateLock()) != nil,
            let identity = socketIdentity,
            let current = try? socketStat(),
            current.st_dev == identity.0, current.st_ino == identity.1
        else { return }
        _ = unlinkat(directoryFD, "api.sock", 0)
        socketIdentity = nil
    }

    func releaseOwnership() {
        if lockFD >= 0 {
            close(lockFD)
            lockFD = -1
        }
    }

    func address() throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(socketPath.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw LocalAPIError.pathTooLong }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes.map { UInt8(bitPattern: $0) })
        }
        return address
    }
}
