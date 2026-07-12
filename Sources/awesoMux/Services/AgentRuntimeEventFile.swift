import Darwin
import Foundation

enum AgentRuntimeEventFile {
    final class ValidatedReadHandle: Sendable {
        let fileDescriptor: Int32
        let size: UInt64
        let inode: ino_t

        init(fileDescriptor: Int32, size: UInt64, inode: ino_t) {
            self.fileDescriptor = fileDescriptor
            self.size = size
            self.inode = inode
        }

        deinit {
            close(fileDescriptor)
        }

        func readData(from offset: UInt64) -> Data? {
            guard offset < size else {
                return Data()
            }

            var result = Data()
            result.reserveCapacity(Int(min(size - offset, UInt64(1 * 1024 * 1024))))

            var readOffset = offset
            var remaining = size - offset
            while remaining > 0 {
                let chunkSize = Int(min(remaining, UInt64(64 * 1024)))
                var buffer = [UInt8](repeating: 0, count: chunkSize)
                let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer in
                    pread(fileDescriptor, rawBuffer.baseAddress, chunkSize, off_t(readOffset))
                }

                if bytesRead < 0 {
                    if errno == EINTR {
                        continue
                    }
                    return nil
                }

                if bytesRead == 0 {
                    break
                }

                result.append(contentsOf: buffer.prefix(bytesRead))
                readOffset += UInt64(bytesRead)
                remaining -= UInt64(bytesRead)
            }

            return result
        }
    }

    static func prepare(
        at url: URL,
        effectiveUID: uid_t = geteuid()
    ) -> Bool {
        guard prepareDirectory(at: url.deletingLastPathComponent(), effectiveUID: effectiveUID) else {
            return false
        }

        return prepareFile(at: url, effectiveUID: effectiveUID)
    }

    enum TruncateOutcome: Equatable {
        /// The existing file was validated and truncated in place; its inode is
        /// unchanged, so a watching dispatch source does not need re-arming.
        case truncatedInPlace
        /// The file could not be opened or validated as our own regular file
        /// (missing, symlink, wrong owner, race). The caller must rotate the
        /// inode (unlink + recreate) and re-arm.
        case rotationRequired
    }

    /// Truncate an existing event file to zero length, but only after opening it
    /// by name with `O_NOFOLLOW` and validating the *descriptor* (regular file,
    /// owned by us). A same-UID process can atomically swap the event file for a
    /// symlink in the window before truncation; following it would zero an
    /// arbitrary same-UID-writable target. Validating the descriptor — not the
    /// path — closes that TOCTOU window.
    static func truncate(
        at url: URL,
        effectiveUID: uid_t = geteuid()
    ) -> TruncateOutcome {
        let fd = open(url.path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            return .rotationRequired
        }
        defer { close(fd) }

        var st = stat()
        guard fstat(fd, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFREG,
              st.st_uid == effectiveUID,
              ftruncate(fd, 0) == 0 else {
            return .rotationRequired
        }

        return .truncatedInPlace
    }

    static func openForReading(
        at url: URL,
        effectiveUID: uid_t = geteuid()
    ) -> ValidatedReadHandle? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            return nil
        }

        var st = stat()
        guard fstat(fd, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFREG,
              st.st_uid == effectiveUID else {
            close(fd)
            return nil
        }

        return ValidatedReadHandle(
            fileDescriptor: fd,
            size: UInt64(st.st_size),
            inode: st.st_ino
        )
    }

    private static func prepareDirectory(at url: URL, effectiveUID: uid_t) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true
            )
        } catch {
            return false
        }

        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            return false
        }
        defer { close(fd) }

        var st = stat()
        guard fstat(fd, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFDIR,
              st.st_uid == effectiveUID else {
            return false
        }

        return fchmod(fd, S_IRWXU) == 0
    }

    private static func prepareFile(at url: URL, effectiveUID: uid_t) -> Bool {
        let createFD = open(
            url.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )

        if createFD >= 0 {
            defer { close(createFD) }
            return validateAndSetPermissions(fileDescriptor: createFD, effectiveUID: effectiveUID)
        }

        guard errno == EEXIST else {
            return false
        }

        let existingFD = open(url.path, O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC)
        guard existingFD >= 0 else {
            return false
        }
        defer { close(existingFD) }

        return validateAndSetPermissions(fileDescriptor: existingFD, effectiveUID: effectiveUID)
    }

    private static func validateAndSetPermissions(
        fileDescriptor: Int32,
        effectiveUID: uid_t
    ) -> Bool {
        var st = stat()
        guard fstat(fileDescriptor, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFREG,
              st.st_uid == effectiveUID else {
            return false
        }

        return fchmod(fileDescriptor, S_IRUSR | S_IWUSR) == 0
    }
}
