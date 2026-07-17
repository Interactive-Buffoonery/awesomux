import AppKit
import AwesoMuxCore
import Darwin
import Foundation
import ImageIO
import UnicodeHygiene

enum RemoteHandoff {
    static let maximumByteCount = 10 * 1024 * 1024
    static let maximumReceiptByteCount = 4 * 1024
    static let maximumDecodedPixelCount = 32 * 1024 * 1024

    enum Candidate: Equatable, Sendable {
        case markdown(URL)
        case png(Data)
        case tiff(Data)
    }

    enum Failure: Error, Equatable, Sendable {
        case sourceUnavailable
        case unsupportedHelper
        case transferFailed
        case unsafeResponse
        case destinationChanged
    }

    struct Authority: Sendable {
        let appSessionID: TerminalSession.ID
        let paneID: TerminalPane.ID
        let terminalSessionID: TerminalSessionID
        let executionPlan: PaneExecutionPlan
        let remote: RemoteTarget
    }

    struct SourceSnapshot: Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
        let size: Int
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64

        init?(_ status: stat) {
            guard status.st_size >= 0, status.st_size <= off_t(Int.max) else { return nil }
            device = UInt64(status.st_dev)
            inode = UInt64(status.st_ino)
            size = Int(status.st_size)
            modifiedSeconds = Int64(status.st_mtimespec.tv_sec)
            modifiedNanoseconds = Int64(status.st_mtimespec.tv_nsec)
            changedSeconds = Int64(status.st_ctimespec.tv_sec)
            changedNanoseconds = Int64(status.st_ctimespec.tv_nsec)
        }
    }

    struct PreparedSource: Sendable {
        let url: URL
        let displayName: String
        let snapshot: SourceSnapshot
        let isTemporary: Bool

        var byteCount: Int { snapshot.size }

        func openValidated() throws -> Int32 {
            let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw Failure.sourceUnavailable }
            var status = stat()
            guard fstat(descriptor, &status) == 0,
                (status.st_mode & S_IFMT) == S_IFREG,
                SourceSnapshot(status) == snapshot
            else {
                close(descriptor)
                throw Failure.sourceUnavailable
            }
            return descriptor
        }

        func cleanup() {
            if isTemporary { try? FileManager.default.removeItem(at: url) }
        }
    }

    private struct Receipt: Decodable {
        let path: String
        let bytes: Int
    }

    @MainActor
    static var confirmationProvider:
        @MainActor (
            _ remote: RemoteTarget,
            _ displayName: String,
            _ proposedDirectory: String,
            _ window: NSWindow?
        ) async -> Bool = presentConfirmation

    @MainActor
    static var failurePresenter: @MainActor (Failure, NSWindow?) -> Void = presentFailure

    @MainActor
    static func presentBusy(window: NSWindow?) {
        if window?.attachedSheet != nil {
            NSSound.beep()
            TerminalAccessibilityAnnouncer.announce(
                String(localized: "A file transfer is already in progress", comment: "Remote handoff busy accessibility status")
            )
            return
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "A file transfer is already in progress", comment: "Remote handoff busy indication")
        alert.addButton(withTitle: String(localized: "OK", comment: "Dismiss remote handoff busy indication"))
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    static func prepare(_ candidate: Candidate) async throws -> PreparedSource {
        switch candidate {
        case .markdown(let url):
            let ext = url.pathExtension.lowercased()
            guard ["md", "markdown"].contains(ext) else { throw Failure.sourceUnavailable }
            return try preparedSource(at: url, isTemporary: false)

        case .png(let data):
            guard data.count <= maximumByteCount else { throw Failure.sourceUnavailable }
            return try await Task.detached(priority: .userInitiated) {
                try materializeImage(data)
            }.value

        case .tiff(let data):
            guard data.count <= maximumByteCount else { throw Failure.sourceUnavailable }
            return try await Task.detached(priority: .userInitiated) {
                guard let pixelCount = decodedPixelCount(in: data),
                    pixelCount <= maximumDecodedPixelCount,
                    let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]),
                    png.count <= maximumByteCount
                else {
                    throw Failure.sourceUnavailable
                }
                return try materializeImage(png)
            }.value
        }
    }

    private static func decodedPixelCount(in data: Data) -> Int? {
        guard
            let source = CGImageSourceCreateWithData(
                data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary
            ),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
            let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
            width > 0,
            height > 0,
            width <= maximumDecodedPixelCount / height
        else {
            return nil
        }
        return width * height
    }

    private static func materializeImage(_ data: Data) throws -> PreparedSource {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(imagePasteDirectoryName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url =
                directory
                .appendingPathComponent("pasted-image-\(UUID().uuidString)")
                .appendingPathExtension("png")
            try data.write(to: url, options: .atomic)
            do {
                return try preparedSource(at: url, isTemporary: true)
            } catch {
                try? FileManager.default.removeItem(at: url)
                throw error
            }
        } catch {
            throw Failure.sourceUnavailable
        }
    }

    private static func preparedSource(at url: URL, isTemporary: Bool) throws -> PreparedSource {
        var status = stat()
        guard url.isFileURL,
            lstat(url.path, &status) == 0,
            (status.st_mode & S_IFMT) == S_IFREG,
            let snapshot = SourceSnapshot(status),
            snapshot.size <= maximumByteCount
        else {
            throw Failure.sourceUnavailable
        }
        let sanitized = UnicodeHygiene.sanitize(
            url.lastPathComponent,
            maxLength: 120,
            stripInvisibleRoutingScalars: true
        )
        return PreparedSource(
            url: url,
            displayName: sanitized.isEmpty ? "file" : sanitized,
            snapshot: snapshot,
            isTemporary: isTemporary
        )
    }

    static func helperSupportsHandoff(
        controlPath: String,
        remote: RemoteTarget,
        helperPath: String
    ) async -> Bool {
        let command = AmxBackend.bridgeHelperVersionCommand(
            controlPath: controlPath,
            remote: remote,
            helperPath: helperPath
        )
        guard let data = try? await BridgeExecChannel.run(command: command, stdin: nil) else {
            return false
        }
        return advertisesHandoff(String(decoding: data, as: UTF8.self))
    }

    static func advertisesHandoff(_ versionOutput: String) -> Bool {
        versionOutput.split(whereSeparator: \.isNewline).contains {
            $0.trimmingCharacters(in: .whitespaces) == "awesomux-handoff-v1"
        }
    }

    static func transfer(
        source: PreparedSource,
        remote: RemoteTarget,
        controlPath: String,
        helperPath: String,
        sessionID: TerminalSessionID,
        executableURL: URL = URL(fileURLWithPath: "/usr/bin/ssh"),
        timeout: DispatchTimeInterval = .seconds(90)
    ) async throws -> Data {
        try Task.checkCancellation()
        let sourceFD = try source.openValidated()
        defer { close(sourceFD) }

        let remoteCommand = [
            shellQuote(helperPath),
            "receive-handoff",
            "--session", shellQuote(sessionID.rawValue),
            "--name", shellQuote(source.displayName),
            "--expected-bytes", String(source.byteCount),
        ].joined(separator: " ")

        let execution = RemoteHandoffExecution()
        execution.process.executableURL = executableURL
        execution.process.arguments = transferArguments(
            remote: remote,
            controlPath: controlPath,
            remoteCommand: remoteCommand
        )
        execution.process.standardInput = execution.stdinPipe
        execution.process.standardOutput = execution.stdoutPipe
        execution.process.standardError = FileHandle.nullDevice
        _ = fcntl(execution.stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        do {
            try execution.process.run()
        } catch {
            throw Failure.transferFailed
        }

        let outputTooLarge = HandoffFlag()
        let stdoutTask = Task.detached {
            var output = Data()
            let reader = execution.stdoutPipe.fileHandleForReading
            while let chunk = try? reader.read(upToCount: 1024), !chunk.isEmpty {
                guard output.count + chunk.count <= maximumReceiptByteCount else {
                    outputTooLarge.set()
                    execution.terminate()
                    break
                }
                output.append(chunk)
            }
            return output
        }

        let writerTask = Task.detached {
            let result = stream(
                sourceFD: sourceFD,
                byteCount: source.byteCount,
                to: execution.stdinPipe.fileHandleForWriting.fileDescriptor
            )
            try? execution.stdinPipe.fileHandleForWriting.close()
            return result
        }
        let timedOut = HandoffFlag()
        let timeoutTimer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        timeoutTimer.schedule(deadline: .now() + timeout)
        timeoutTimer.setEventHandler {
            timedOut.set()
            execution.terminateThenKill()
        }
        timeoutTimer.resume()
        let waitTask = Task.detached { execution.process.waitUntilExit() }

        await withTaskCancellationHandler {
            await waitTask.value
        } onCancel: {
            execution.terminateThenKill()
        }
        timeoutTimer.cancel()

        let wroteAllBytes = await writerTask.value
        let output = await stdoutTask.value
        try Task.checkCancellation()
        guard !timedOut.isSet,
            !outputTooLarge.isSet,
            wroteAllBytes,
            execution.process.terminationStatus == 0
        else {
            throw Failure.transferFailed
        }
        return output
    }

    static func transferArguments(
        remote: RemoteTarget,
        controlPath: String,
        remoteCommand: String
    ) -> [String] {
        [
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(controlPath)",
            "-o", "ControlPersist=60",
            "-o", "ServerAliveInterval=15",
            "-o", "ConnectTimeout=10",
            "--", remote.sshDestination, remoteCommand,
        ]
    }

    static func authorityMatches(_ authority: Authority, pane: TerminalPane?) -> Bool {
        pane?.id == authority.paneID
            && pane?.executionPlan == authority.executionPlan
            && pane?.terminalSessionID == authority.terminalSessionID
    }

    static func validatedReceiptPath(
        _ data: Data,
        remoteHome: String,
        sessionID: TerminalSessionID,
        expectedBytes: Int
    ) -> String? {
        guard data.count <= maximumReceiptByteCount,
            remoteHome.hasPrefix("/"),
            !UnicodeHygiene.containsUnsafePathScalars(remoteHome),
            let receipt = try? JSONDecoder().decode(Receipt.self, from: data),
            receipt.bytes == expectedBytes,
            receipt.path.hasPrefix("/"),
            !UnicodeHygiene.containsUnsafePathScalars(receipt.path)
        else {
            return nil
        }

        let expectedDirectory = URL(fileURLWithPath: remoteHome, isDirectory: true)
            .appendingPathComponent(".awesomux", isDirectory: true)
            .appendingPathComponent("handoffs", isDirectory: true)
            .appendingPathComponent(sessionID.rawValue, isDirectory: true)
            .standardizedFileURL.path
        let standardizedPath = URL(fileURLWithPath: receipt.path).standardizedFileURL.path
        guard standardizedPath != expectedDirectory,
            standardizedPath.hasPrefix(expectedDirectory + "/")
        else {
            return nil
        }
        return standardizedPath
    }

    @MainActor
    private static func presentConfirmation(
        remote: RemoteTarget,
        displayName: String,
        proposedDirectory: String,
        window: NSWindow?
    ) async -> Bool {
        let alert = NSAlert()
        alert.messageText = String(
            localized: "Transfer file to \(remote.sshDestination)?",
            comment: "Remote clipboard handoff confirmation title. Argument is the declared SSH destination."
        )
        alert.informativeText = String(
            localized: "Transfer \(displayName) to \(proposedDirectory)",
            comment: "Remote clipboard handoff confirmation body. Arguments are a safe display filename and proposed remote directory."
        )
        alert.addButton(withTitle: String(localized: "Transfer", comment: "Approve remote clipboard handoff button"))
        alert.addButton(withTitle: String(localized: "Cancel", comment: "Cancel remote clipboard handoff button"))
        alert.buttons[0].setAccessibilityLabel(
            String(
                localized: "Transfer file to declared SSH destination", comment: "VoiceOver label for approving remote clipboard handoff")
        )
        let response: NSApplication.ModalResponse
        if let window {
            let cancellation = HandoffSheetCancellation(alert: alert, window: window)
            response = await withTaskCancellationHandler {
                guard cancellation.shouldPresent else { return .abort }
                return await withCheckedContinuation { continuation in
                    alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
                }
            } onCancel: {
                cancellation.cancel()
            }
        } else {
            response = alert.runModal()
        }
        return response == .alertFirstButtonReturn
    }

    @MainActor
    private static func presentFailure(_ failure: Failure, window: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        switch failure {
        case .unsupportedHelper:
            alert.messageText = String(localized: "Remote file transfer is unsupported", comment: "Remote handoff unsupported error title")
            alert.informativeText = String(
                localized: "The declared destination does not have a compatible awesoMux helper.",
                comment: "Remote handoff unsupported error body")
        case .sourceUnavailable:
            alert.messageText = String(localized: "The source is unavailable or changed", comment: "Remote handoff source error title")
        case .unsafeResponse:
            alert.messageText = String(
                localized: "The remote helper returned an unsafe response", comment: "Remote handoff unsafe response error title")
        case .destinationChanged:
            alert.messageText = String(localized: "The destination changed or closed", comment: "Remote handoff destination error title")
        case .transferFailed:
            alert.messageText = String(localized: "Remote file transfer failed", comment: "Remote handoff transfer error title")
        }
        alert.addButton(withTitle: String(localized: "OK", comment: "Dismiss remote handoff error button"))
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private static func shellQuote(_ value: String) -> String {
        value.isEmpty ? "''" : "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func stream(sourceFD: Int32, byteCount: Int, to outputFD: Int32) -> Bool {
        var offset: off_t = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while offset < byteCount {
            let amount = min(buffer.count, byteCount - Int(offset))
            let bytesRead = buffer.withUnsafeMutableBytes { pread(sourceFD, $0.baseAddress, amount, offset) }
            if bytesRead < 0, errno == EINTR { continue }
            guard bytesRead > 0 else { return false }

            var written = 0
            while written < bytesRead {
                let result = buffer.withUnsafeBytes {
                    write(outputFD, $0.baseAddress!.advanced(by: written), bytesRead - written)
                }
                if result < 0, errno == EINTR { continue }
                guard result > 0 else { return false }
                written += result
            }
            offset += off_t(bytesRead)
        }
        return true
    }
}

private final class HandoffSheetCancellation: @unchecked Sendable {
    private weak var alert: NSAlert?
    private weak var window: NSWindow?
    private let lock = NSLock()
    private var cancellationRequested = false

    init(alert: NSAlert, window: NSWindow) {
        self.alert = alert
        self.window = window
    }

    var shouldPresent: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !cancellationRequested
    }

    func cancel() {
        lock.lock()
        cancellationRequested = true
        lock.unlock()
        Task { @MainActor [weak self] in
            guard let self,
                let alert,
                let window,
                window.attachedSheet === alert.window
            else { return }
            window.endSheet(alert.window, returnCode: .abort)
        }
    }
}

private final class WeakHandoffWindow {
    weak var value: NSWindow?

    init(_ value: NSWindow?) {
        self.value = value
    }
}

@MainActor
extension GhosttySurfaceNSView {
    func beginRemoteHandoff(_ candidate: RemoteHandoff.Candidate) {
        guard remoteHandoffTask == nil else {
            RemoteHandoff.presentBusy(window: window)
            return
        }
        guard let remote = pane.executionPlan.remoteTarget else { return }

        let authority = RemoteHandoff.Authority(
            appSessionID: sessionID,
            paneID: paneID,
            terminalSessionID: pane.terminalSessionID,
            executionPlan: pane.executionPlan,
            remote: remote
        )
        let originatingWindow = WeakHandoffWindow(window)

        remoteHandoffTask = Task { @MainActor [weak self] in
            var cleanupSource: RemoteHandoff.PreparedSource?
            defer {
                cleanupSource?.cleanup()
                self?.remoteHandoffTask = nil
            }
            do {
                let source = try await RemoteHandoff.prepare(candidate)
                cleanupSource = source
                try Task.checkCancellation()
                let controlPath = AmxBackend.sshControlPath()
                let remoteHome = await GhosttySurfaceNSView.cachedRemoteHome(
                    controlPath: controlPath,
                    remote: authority.remote
                )
                try Task.checkCancellation()
                guard let remoteHome,
                    !UnicodeHygiene.containsUnsafePathScalars(remoteHome)
                else {
                    throw RemoteHandoff.Failure.unsupportedHelper
                }
                let helperPath = BridgeAttachDecision.helperPath(remoteHome: remoteHome)
                let helperIsSupported = await RemoteHandoff.helperSupportsHandoff(
                    controlPath: controlPath,
                    remote: authority.remote,
                    helperPath: helperPath
                )
                try Task.checkCancellation()
                guard helperIsSupported else {
                    throw RemoteHandoff.Failure.unsupportedHelper
                }

                let proposedDirectory = "~/.awesomux/handoffs/\(authority.terminalSessionID.rawValue)/"
                guard
                    await RemoteHandoff.confirmationProvider(
                        authority.remote,
                        source.displayName,
                        proposedDirectory,
                        originatingWindow.value
                    )
                else {
                    TerminalAccessibilityAnnouncer.announce(
                        String(localized: "Remote file transfer cancelled", comment: "Remote handoff cancellation accessibility status")
                    )
                    return
                }
                try Task.checkCancellation()

                let receipt = try await RemoteHandoff.transfer(
                    source: source,
                    remote: authority.remote,
                    controlPath: controlPath,
                    helperPath: helperPath,
                    sessionID: authority.terminalSessionID
                )
                guard
                    let remotePath = RemoteHandoff.validatedReceiptPath(
                        receipt,
                        remoteHome: remoteHome,
                        sessionID: authority.terminalSessionID,
                        expectedBytes: source.byteCount
                    )
                else {
                    throw RemoteHandoff.Failure.unsafeResponse
                }

                guard let self,
                    self.runtime.cachedSurfaceView(for: authority.paneID) === self,
                    self.surface != nil,
                    let currentPane = self.sessionStore
                        .session(id: authority.appSessionID)?
                        .layout.pane(id: authority.paneID),
                    RemoteHandoff.authorityMatches(authority, pane: currentPane),
                    self.runtime.sendText(
                        TerminalInsertionEscaping.escape(remotePath),
                        toPane: authority.paneID,
                        focusingSurface: false
                    )
                else {
                    throw RemoteHandoff.Failure.destinationChanged
                }
                TerminalAccessibilityAnnouncer.announce(
                    String(localized: "Remote file transfer complete", comment: "Remote handoff completion accessibility status")
                )
            } catch is CancellationError {
                return
            } catch let failure as RemoteHandoff.Failure {
                guard !Task.isCancelled else { return }
                RemoteHandoff.failurePresenter(failure, originatingWindow.value)
            } catch {
                guard !Task.isCancelled else { return }
                RemoteHandoff.failurePresenter(.transferFailed, originatingWindow.value)
            }
        }
    }
}

private final class RemoteHandoffExecution: @unchecked Sendable {
    let process = Process()
    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()

    func terminate() {
        if process.isRunning { process.terminate() }
    }

    func kill() {
        if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
    }

    func terminateThenKill() {
        terminate()
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1) { [self] in
            kill()
        }
    }
}

private final class HandoffFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock(); defer { lock.unlock() }
        value = true
    }
}
