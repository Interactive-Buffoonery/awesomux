#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif
import Dispatch
import Foundation
import AwesoMuxBridgeProtocol

#if canImport(Glibc) || canImport(Musl)
    // Neither Swift libc overlay declares renameat2 (hidden behind _GNU_SOURCE)
    // and the Static Linux SDK's musl doesn't export the wrapper symbol at all —
    // but every Linux libc exports syscall(2), and the kernel ABI is stable.
    // Integer-only arguments make the variadic-vs-fixed call safe on both
    // x86_64 SysV and aarch64 AAPCS. linkat(2)+unlinkat(2) is the remaining
    // fallback if this ever breaks (weaker crash-cleanup: a hard kill between
    // link and unlink would leave a stale temp hard link).
    #if arch(x86_64)
        private let sysRenameat2 = 316
    #elseif arch(arm64)
        private let sysRenameat2 = 276
    #endif
    private let renameNoreplaceFlag: UInt32 = 1  // linux/fs.h RENAME_NOREPLACE

    @_silgen_name("syscall")
    private func linuxSyscallRenameat2(
        _ number: Int, _ olddirfd: Int32, _ oldpath: UnsafePointer<CChar>?,
        _ newdirfd: Int32, _ newpath: UnsafePointer<CChar>?, _ flags: UInt32
    ) -> Int
#endif

/// Receives one bounded handoff into the current user's private session directory.
public enum HandoffReceiver {
    public static let maximumByteCount = 10 * 1024 * 1024

    public struct Receipt: Codable, Equatable, Sendable {
        public let path: String
        public let bytes: Int
    }

    public enum ReceiveError: Error, Equatable, Sendable {
        case invalidArguments
        case unsafeDirectory
        case createFailed
        case readFailed
        case writeFailed
        case syncFailed
        case publishFailed
    }

    public static func receive(
        session: String,
        advisoryName: String,
        expectedBytes: Int,
        inputDescriptor: Int32 = STDIN_FILENO,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        effectiveUID: uid_t = geteuid(),
        makeUUID: () -> UUID = UUID.init
    ) throws -> Receipt {
        guard TerminalSessionID.isValid(session),
            (0...maximumByteCount).contains(expectedBytes),
            homeDirectory.path.hasPrefix("/")
        else {
            throw ReceiveError.invalidArguments
        }

        let homeFD = open(homeDirectory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard homeFD >= 0 else { throw ReceiveError.unsafeDirectory }
        defer { close(homeFD) }

        let awesomuxFD = try ownerOnlyDirectory(named: ".awesomux", under: homeFD, effectiveUID: effectiveUID)
        defer { close(awesomuxFD) }
        let handoffsFD = try ownerOnlyDirectory(named: "handoffs", under: awesomuxFD, effectiveUID: effectiveUID)
        defer { close(handoffsFD) }
        let sessionFD = try ownerOnlyDirectory(named: session, under: handoffsFD, effectiveUID: effectiveUID)
        defer { close(sessionFD) }

        let suffix = supportedExtension(in: advisoryName)
        let stem = safeStem(from: advisoryName, makeUUID: makeUUID)
        let unique = makeUUID().uuidString.lowercased()
        let finalName = suffix.map { "\(stem)-\(unique).\($0)" } ?? "\(stem)-\(unique)"
        let temporaryName = ".handoff-\(makeUUID().uuidString.lowercased()).tmp"
        let signalCleanup =
            inputDescriptor == STDIN_FILENO
            ? HandoffSignalCleanup(directoryFD: sessionFD, temporaryName: temporaryName)
            : nil
        defer { signalCleanup?.stop() }

        let temporaryFD = temporaryName.withCString {
            openat(sessionFD, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        }
        guard temporaryFD >= 0 else { throw ReceiveError.createFailed }
        var temporaryIsOpen = true
        var shouldRemoveTemporary = true
        defer {
            if temporaryIsOpen { close(temporaryFD) }
            if shouldRemoveTemporary {
                temporaryName.withCString { _ = unlinkat(sessionFD, $0, 0) }
            }
        }

        var status = stat()
        guard fstat(temporaryFD, &status) == 0,
            (status.st_mode & S_IFMT) == S_IFREG,
            status.st_uid == effectiveUID,
            (status.st_mode & ~mode_t(S_IFMT)) == (S_IRUSR | S_IWUSR)
        else {
            throw ReceiveError.createFailed
        }

        try copyExactly(
            expectedBytes,
            from: inputDescriptor,
            to: temporaryFD
        )
        guard fsync(temporaryFD) == 0 else { throw ReceiveError.syncFailed }
        let closeResult = close(temporaryFD)
        temporaryIsOpen = false
        guard closeResult == 0 else { throw ReceiveError.syncFailed }

        #if canImport(Darwin)
            let published = temporaryName.withCString { temporary in
                finalName.withCString { final in
                    renameatx_np(sessionFD, temporary, sessionFD, final, UInt32(RENAME_EXCL))
                }
            }
            guard published == 0 else { throw ReceiveError.publishFailed }
            shouldRemoveTemporary = false
        #elseif canImport(Glibc) || canImport(Musl)
            // renameat2(RENAME_NOREPLACE): Linux's exact equivalent of Darwin's
            // RENAME_EXCL — atomic no-overwrite publish with the temporary name gone
            // in the same operation, so crash-cleanup semantics match Darwin exactly.
            // Routed through syscall(2) rather than a direct symbol bind (see
            // top-of-file) so glibc and musl share one publish path.
            let published = temporaryName.withCString { temporary in
                finalName.withCString { final in
                    linuxSyscallRenameat2(
                        sysRenameat2, sessionFD, temporary, sessionFD, final, renameNoreplaceFlag)
                }
            }
            guard published == 0 else { throw ReceiveError.publishFailed }
            shouldRemoveTemporary = false
        #endif
        _ = fsync(sessionFD)

        let path =
            homeDirectory
            .appendingPathComponent(".awesomux", isDirectory: true)
            .appendingPathComponent("handoffs", isDirectory: true)
            .appendingPathComponent(session, isDirectory: true)
            .appendingPathComponent(finalName)
            .path
        return Receipt(path: path, bytes: expectedBytes)
    }

    private static func ownerOnlyDirectory(
        named name: String,
        under parentFD: Int32,
        effectiveUID: uid_t
    ) throws -> Int32 {
        let mkdirResult = name.withCString { mkdirat(parentFD, $0, 0o700) }
        guard mkdirResult == 0 || errno == EEXIST else { throw ReceiveError.createFailed }

        let descriptor = name.withCString {
            openat(parentFD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw ReceiveError.unsafeDirectory }

        var status = stat()
        guard fstat(descriptor, &status) == 0,
            (status.st_mode & S_IFMT) == S_IFDIR,
            status.st_uid == effectiveUID,
            (status.st_mode & ~mode_t(S_IFMT)) == (S_IRUSR | S_IWUSR | S_IXUSR)
        else {
            close(descriptor)
            throw ReceiveError.unsafeDirectory
        }
        return descriptor
    }

    private static func copyExactly(_ count: Int, from inputFD: Int32, to outputFD: Int32) throws {
        var remaining = count
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)

        while remaining > 0 {
            let amount = min(remaining, buffer.count)
            let bytesRead = buffer.withUnsafeMutableBytes { read(inputFD, $0.baseAddress, amount) }
            if bytesRead < 0, errno == EINTR { continue }
            guard bytesRead > 0 else { throw ReceiveError.readFailed }

            var offset = 0
            while offset < bytesRead {
                let bytesWritten = buffer.withUnsafeBytes {
                    write(outputFD, $0.baseAddress!.advanced(by: offset), bytesRead - offset)
                }
                if bytesWritten < 0, errno == EINTR { continue }
                guard bytesWritten > 0 else { throw ReceiveError.writeFailed }
                offset += bytesWritten
            }
            remaining -= bytesRead
        }

        var extra: UInt8 = 0
        while true {
            let bytesRead = read(inputFD, &extra, 1)
            if bytesRead < 0, errno == EINTR { continue }
            guard bytesRead == 0 else { throw ReceiveError.readFailed }
            return
        }
    }

    private static func supportedExtension(in name: String) -> String? {
        let ext = (name as NSString).pathExtension.lowercased()
        return ["png", "md", "markdown"].contains(ext) ? ext : nil
    }

    private static func safeStem(from name: String, makeUUID: () -> UUID) -> String {
        let basename = (name as NSString).lastPathComponent
        let rawStem = (basename as NSString).deletingPathExtension
        let scalars = rawStem.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
        }
        let stem = String(String.UnicodeScalarView(scalars)).prefix(80)
        return stem.isEmpty ? "handoff-\(makeUUID().uuidString.lowercased())" : String(stem)
    }
}

#if canImport(Darwin)
    private typealias SignalDisposition = sig_t
#else
    private typealias SignalDisposition = @convention(c) (Int32) -> Void
#endif

private final class HandoffSignalCleanup {
    private let queue = DispatchQueue(label: "com.interactivebuffoonery.awesomux.handoff-signal-cleanup")
    private var sources: [DispatchSourceSignal] = []
    private var previousHandlers: [(Int32, SignalDisposition?)] = []

    init(directoryFD: Int32, temporaryName: String) {
        for signalNumber in [SIGHUP, SIGINT, SIGTERM] {
            previousHandlers.append((signalNumber, signal(signalNumber, SIG_IGN)))
            let source = DispatchSource.makeSignalSource(
                signal: signalNumber,
                queue: queue
            )
            source.setEventHandler {
                temporaryName.withCString { _ = unlinkat(directoryFD, $0, 0) }
                _exit(128 + signalNumber)
            }
            source.resume()
            sources.append(source)
        }
    }

    func stop() {
        sources.forEach { $0.cancel() }
        queue.sync {}
        sources.removeAll()
        for (signalNumber, handler) in previousHandlers {
            signal(signalNumber, handler)
        }
        previousHandlers.removeAll()
    }
}
