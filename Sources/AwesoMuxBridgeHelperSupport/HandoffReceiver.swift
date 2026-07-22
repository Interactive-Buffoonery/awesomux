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

#if canImport(Glibc)
    // glibc >= 2.28 ships the renameat2 wrapper, but the Swift overlay hides
    // its declaration behind _GNU_SOURCE. Bind the libc symbol directly; the
    // flag value is stable kernel ABI (linux/fs.h). The Static Linux SDK's
    // musl does not export this symbol at all, so Musl gets its own publish
    // path below rather than sharing this bind.
    @_silgen_name("renameat2")
    private func linuxRenameat2(
        _ olddirfd: Int32, _ oldpath: UnsafePointer<CChar>?,
        _ newdirfd: Int32, _ newpath: UnsafePointer<CChar>?,
        _ flags: UInt32
    ) -> Int32
    private let linuxRenameNoreplace: UInt32 = 1
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
        #elseif canImport(Glibc)
            // renameat2(RENAME_NOREPLACE): Linux's exact equivalent of Darwin's
            // RENAME_EXCL — atomic no-overwrite publish with the temporary name gone
            // in the same operation, so crash-cleanup semantics match Darwin exactly.
            // The wrapper ships in glibc >= 2.28 (Ubuntu 24.04 glibc is newer), but
            // the overlay hides the declaration behind _GNU_SOURCE, so this binds
            // the symbol directly (see top-of-file).
            let published = temporaryName.withCString { temporary in
                finalName.withCString { final in
                    linuxRenameat2(sessionFD, temporary, sessionFD, final, linuxRenameNoreplace)
                }
            }
            guard published == 0 else { throw ReceiveError.publishFailed }
            shouldRemoveTemporary = false
        #elseif canImport(Musl)
            // The Static Linux SDK's musl does not export a renameat2 wrapper, so the
            // static helper publishes via linkat(2): link fails with EEXIST when the
            // final name exists (same no-overwrite guarantee), and the deferred
            // unlinkat drops the temporary name. Weaker crash-cleanup than rename:
            // a hard kill between link and unlink leaves a stale .handoff-*.tmp hard
            // link to the published file — clutter, not corruption.
            let published = temporaryName.withCString { temporary in
                finalName.withCString { final in
                    linkat(sessionFD, temporary, sessionFD, final, 0)
                }
            }
            guard published == 0 else { throw ReceiveError.publishFailed }
            // shouldRemoveTemporary stays true: the deferred unlinkat removes exactly
            // the surplus temporary hard link, never the final name.
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
