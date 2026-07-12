import Darwin
import Foundation

enum AgentHookEventFileAppender {
    struct FileInfo: Equatable {
        var isRegularFile: Bool
        var ownerUID: uid_t
    }

    static func append(
        _ data: Data,
        to path: String,
        effectiveUID: uid_t = geteuid()
    ) throws {
        let fd = open(path, O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(fd) }

        try validate(fileInfo: try fileInfo(for: fd), effectiveUID: effectiveUID)
        try writeAll(data, to: fd)
    }

    static func validate(fileInfo: FileInfo, effectiveUID: uid_t) throws {
        guard fileInfo.isRegularFile else {
            throw POSIXError(.EINVAL)
        }
        guard fileInfo.ownerUID == effectiveUID else {
            throw POSIXError(.EACCES)
        }
    }

    private static func fileInfo(for fileDescriptor: Int32) throws -> FileInfo {
        var st = stat()
        guard fstat(fileDescriptor, &st) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        return FileInfo(
            isRegularFile: (st.st_mode & S_IFMT) == S_IFREG,
            ownerUID: st.st_uid
        )
    }

    private static func writeAll(_ data: Data, to fileDescriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            guard var cursor = buffer.baseAddress else {
                return
            }

            var remainingByteCount = buffer.count
            while remainingByteCount > 0 {
                let result = Darwin.write(fileDescriptor, cursor, remainingByteCount)
                if result < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                guard result > 0 else {
                    throw POSIXError(.EIO)
                }

                cursor = cursor.advanced(by: result)
                remainingByteCount -= result
            }
        }
    }
}
