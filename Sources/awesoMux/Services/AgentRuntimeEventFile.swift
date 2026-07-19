import Darwin
import Foundation

enum AgentRuntimeEventFile {
    struct Generation: Equatable, Sendable {
        let inode: ino_t
        let size: UInt64
        let modificationSeconds: Int
        let modificationNanoseconds: Int
        let changeSeconds: Int
        let changeNanoseconds: Int
    }

    final class ValidatedReadHandle: Sendable {
        let fileDescriptor: Int32
        let generation: Generation

        var size: UInt64 { generation.size }
        var inode: ino_t { generation.inode }

        init(fileDescriptor: Int32, generation: Generation) {
            self.fileDescriptor = fileDescriptor
            self.generation = generation
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
                    AgentRuntimeEventFile.preadRetryingInterrupts(
                        fileDescriptor: fileDescriptor,
                        buffer: rawBuffer.baseAddress,
                        byteCount: chunkSize,
                        offset: readOffset
                    )
                }

                if bytesRead < 0 {
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

    static func validatedGeneration(
        fileDescriptor: Int32,
        effectiveUID: uid_t = geteuid()
    ) -> Generation? {
        var st = stat()
        guard fstat(fileDescriptor, &st) == 0,
            (st.st_mode & S_IFMT) == S_IFREG,
            st.st_uid == effectiveUID,
            st.st_size >= 0
        else {
            return nil
        }
        return Generation(
            inode: st.st_ino,
            size: UInt64(st.st_size),
            modificationSeconds: st.st_mtimespec.tv_sec,
            modificationNanoseconds: st.st_mtimespec.tv_nsec,
            changeSeconds: st.st_ctimespec.tv_sec,
            changeNanoseconds: st.st_ctimespec.tv_nsec
        )
    }

    static func readFinalCompleteNonemptyLine(
        fileDescriptor: Int32,
        size: UInt64,
        maximumByteCount: Int
    ) -> Data? {
        guard size > 0 else { return nil }

        var cursor = size
        var foundTerminator = false
        var reversedLine: [UInt8] = []
        reversedLine.reserveCapacity(min(maximumByteCount, 4 * 1024))

        while cursor > 0 {
            let chunkSize = Int(min(cursor, UInt64(4 * 1024)))
            let chunkOffset = cursor - UInt64(chunkSize)
            var chunk = [UInt8](repeating: 0, count: chunkSize)
            let bytesRead = chunk.withUnsafeMutableBytes { buffer in
                preadRetryingInterrupts(
                    fileDescriptor: fileDescriptor,
                    buffer: buffer.baseAddress,
                    byteCount: chunkSize,
                    offset: chunkOffset
                )
            }
            guard bytesRead == chunkSize else { return nil }

            for byte in chunk.prefix(bytesRead).reversed() {
                if !foundTerminator {
                    guard byte == 0x0A else { return nil }
                    foundTerminator = true
                    continue
                }
                if byte == 0x0A {
                    if reversedLine.isEmpty || reversedLine == [0x0D] {
                        reversedLine.removeAll(keepingCapacity: true)
                        continue
                    }
                    return normalizedLine(from: reversedLine)
                }
                reversedLine.append(byte)
                guard reversedLine.count <= maximumByteCount + 1 else { return nil }
            }
            cursor = chunkOffset
        }

        guard !reversedLine.isEmpty, reversedLine != [0x0D] else { return nil }
        return normalizedLine(from: reversedLine)
    }

    private static func preadRetryingInterrupts(
        fileDescriptor: Int32,
        buffer: UnsafeMutableRawPointer?,
        byteCount: Int,
        offset: UInt64
    ) -> Int {
        while true {
            let bytesRead = pread(fileDescriptor, buffer, byteCount, off_t(offset))
            if bytesRead < 0, errno == EINTR {
                continue
            }
            return bytesRead
        }
    }

    private static func normalizedLine(from reversedLine: [UInt8]) -> Data? {
        var bytes = Array(reversedLine.reversed())
        if bytes.last == 0x0D {
            bytes.removeLast()
        }
        return bytes.isEmpty ? nil : Data(bytes)
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
            ftruncate(fd, 0) == 0
        else {
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

        guard
            let generation = validatedGeneration(
                fileDescriptor: fd,
                effectiveUID: effectiveUID
            )
        else {
            close(fd)
            return nil
        }

        return ValidatedReadHandle(
            fileDescriptor: fd,
            generation: generation
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
            st.st_uid == effectiveUID
        else {
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
            st.st_uid == effectiveUID
        else {
            return false
        }

        return fchmod(fileDescriptor, S_IRUSR | S_IWUSR) == 0
    }
}
