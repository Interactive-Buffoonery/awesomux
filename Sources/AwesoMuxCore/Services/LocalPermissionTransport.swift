import Darwin
import Foundation

public struct LocalPermissionEndpoint: Codable, Sendable {
    public static let environmentKey = "AWESOMUX_LOCAL_PERMISSION"
    public let target: LocalPermissionTarget
    public let directory: String
    public let socket: String?

    public init(target: LocalPermissionTarget, directory: String, socket: String?) {
        self.target = target
        self.directory = directory
        self.socket = socket
    }

    public static func environmentFile(for eventFile: URL) -> URL {
        eventFile.appendingPathExtension("permission.json")
    }

    public static func parse(_ value: String?) -> Self? {
        guard let value, value.hasPrefix("/"), value.utf8.count < 4096 else { return nil }
        return LocalPermissionFiles.read(Self.self, at: URL(fileURLWithPath: value))
    }

    public func file(_ prefix: String, id: UUID) -> URL {
        URL(fileURLWithPath: directory).appendingPathComponent("\(prefix)-\(id.uuidString).json")
    }
}

public enum LocalPermissionFiles {
    public static let maximumBytes = 8192

    public static func read<T: Decodable>(_ type: T.Type, at url: URL) -> T? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(),
            info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o077 == 0,
            info.st_size > 0, info.st_size <= maximumBytes
        else { return nil }
        var bytes = [UInt8](repeating: 0, count: maximumBytes + 1)
        let count = Darwin.read(fd, &bytes, bytes.count)
        guard count > 0, count <= maximumBytes else { return nil }
        return try? JSONDecoder().decode(T.self, from: Data(bytes.prefix(count)))
    }

    /// Link publishes a complete owner-only record without replacing an earlier
    /// decision. Both readers reject symlinks, special files and oversized data.
    @discardableResult
    public static func write<T: Encodable>(_ value: T, at url: URL) -> Bool {
        guard let data = try? JSONEncoder().encode(value), data.count <= maximumBytes else { return false }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString)")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        defer { close(fd); unlink(temporary.path) }
        let count = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        return count == data.count && link(temporary.path, url.path) == 0
    }

    /// Terminal publication may revoke an escaped choice, never replace it
    /// with another choice or a different invocation. Rename keeps reads whole.
    @discardableResult
    public static func replaceWithTerminalOutcome(_ outcome: LocalPermissionOutcome, at url: URL) -> Bool {
        guard outcome.choice == nil, [.cancelled, .expired, .unknown, .delivered].contains(outcome.state),
            let existing = read(LocalPermissionOutcome.self, at: url), existing.identity == outcome.identity
        else { return false }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString)")
        defer { unlink(temporary.path) }
        guard write(outcome, at: temporary) else { return false }
        return rename(temporary.path, url.path) == 0
    }

    public static func processStartMicroseconds(_ pid: Int32) -> UInt64? {
        guard pid > 1 else { return nil }
        var info = proc_bsdinfo()
        let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        guard size == Int32(MemoryLayout<proc_bsdinfo>.size),
            info.pbi_uid == geteuid(), info.pbi_status != UInt32(SZOMB)
        else { return nil }
        return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
    }

    public static func helperAlive(_ request: LocalPermissionRequest) -> Bool {
        processStartMicroseconds(request.helperPID) == request.helperStartMicroseconds
    }

    public static func address(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path), !path.contains("\0") else { return nil }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8CString.map { UInt8(bitPattern: $0) })
        }
        return address
    }
}
