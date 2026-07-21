import AppKit
import AwesoMuxCore
import Darwin
import Foundation
import ImageIO
import UnicodeHygiene

enum RemoteHandoff {
    // MARK: - Types

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

        func snapshotValidatedContents() throws -> Data {
            let descriptor = try openValidated()
            defer { close(descriptor) }

            var contents = Data(count: byteCount)
            var offset = 0
            while offset < byteCount {
                let amount = min(64 * 1024, byteCount - offset)
                let bytesRead = contents.withUnsafeMutableBytes {
                    pread(
                        descriptor,
                        $0.baseAddress!.advanced(by: offset),
                        amount,
                        off_t(offset)
                    )
                }
                if bytesRead < 0, errno == EINTR { continue }
                guard bytesRead > 0 else { throw Failure.sourceUnavailable }
                offset += bytesRead
            }

            var status = stat()
            guard fstat(descriptor, &status) == 0,
                SourceSnapshot(status) == snapshot
            else {
                throw Failure.sourceUnavailable
            }
            return contents
        }

        func cleanup() {
            if isTemporary { try? FileManager.default.removeItem(at: url) }
        }
    }

    // MARK: - Source Preparation

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
        do {
            let url = try PastedImageFile.materialize(data)
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

    // MARK: - Transfer

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
        let sourceContents = try source.snapshotValidatedContents()

        let remoteCommand = [
            shellQuote(helperPath),
            "receive-handoff",
            "--session", shellQuote(sessionID.rawValue),
            "--name", shellQuote(source.displayName),
            "--expected-bytes", String(source.byteCount),
        ].joined(separator: " ")

        do {
            return try await BoundedProcessRunner.run(
                executableURL: executableURL,
                arguments: sshArguments(
                    remote: remote,
                    controlPath: controlPath,
                    remoteCommand: remoteCommand
                ),
                input: .data(sourceContents),
                maximumOutputByteCount: maximumReceiptByteCount,
                timeout: timeout
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Failure.transferFailed
        }
    }

    static func sshArguments(
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

    // MARK: - Receipt Validation

    private struct Receipt: Decodable {
        let path: String
        let bytes: Int
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

    // MARK: - Presentation

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

    @MainActor
    private static func presentConfirmation(
        remote: RemoteTarget,
        displayName: String,
        proposedDirectory: String,
        window: NSWindow?
    ) async -> Bool {
        guard let window else { return false }
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
        let cancellation = HandoffSheetCancellation(alert: alert, window: window)
        let response = await withTaskCancellationHandler {
            guard cancellation.shouldPresent else { return NSApplication.ModalResponse.abort }
            return await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
        } onCancel: {
            cancellation.cancel()
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
}

final class HandoffSheetCancellation: @unchecked Sendable {
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

// MARK: - UI Orchestration

@MainActor
extension GhosttySurfaceNSView {
    func beginRemoteHandoff(_ candidate: RemoteHandoff.Candidate) {
        guard lifecycleState.remoteHandoffTask == nil else {
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
        let progressIndicator = NSProgressIndicator()
        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false
        progressIndicator.setAccessibilityLabel(
            String(
                localized: "Preparing remote file transfer",
                comment: "Remote handoff initial progress status"
            ))
        addSubview(progressIndicator)
        NSLayoutConstraint.activate([
            progressIndicator.centerXAnchor.constraint(equalTo: centerXAnchor),
            progressIndicator.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        progressIndicator.startAnimation(nil)

        lifecycleState.remoteHandoffTask = Task { @MainActor [weak self, weak originatingWindow = window] in
            var cleanupSource: RemoteHandoff.PreparedSource?
            defer {
                cleanupSource?.cleanup()
                progressIndicator.removeFromSuperview()
                self?.lifecycleState.remoteHandoffTask = nil
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
                let capability = try await RemoteHelperInstaller.capability(
                    remote: authority.remote,
                    controlPath: controlPath,
                    helperPath: helperPath
                )
                try Task.checkCancellation()
                switch capability {
                case .supported:
                    break
                case .probeFailed:
                    throw RemoteHelperInstaller.Failure.helperProbeFailed
                case .missing, .incompatible:
                    try await RemoteHelperInstaller.probePlatform(
                        remote: authority.remote,
                        controlPath: controlPath
                    )
                    guard let bundledHelperURL = RemoteHelperInstaller.bundledHelperURL() else {
                        throw RemoteHelperInstaller.Failure.bundledHelperUnavailable
                    }
                    let helper = try await RemoteHelperInstaller.prepareBundledHelper(at: bundledHelperURL)
                    guard let action = capability.approvalAction else {
                        throw RemoteHelperInstaller.Failure.installationFailed
                    }
                    let outcome = try await RemoteHelperInstaller.performApprovedInstallation(
                        helper: helper,
                        action: action,
                        remote: authority.remote,
                        controlPath: controlPath,
                        remoteHome: remoteHome,
                        helperPath: helperPath,
                        window: originatingWindow,
                        authorityIsCurrent: { [weak self] in
                            guard let self,
                                let currentPane = self.sessionStore
                                    .session(id: authority.appSessionID)?
                                    .layout.pane(id: authority.paneID)
                            else {
                                return false
                            }
                            return RemoteHandoff.authorityMatches(authority, pane: currentPane)
                        }
                    )
                    if outcome == .cancelled {
                        TerminalAccessibilityAnnouncer.announce(
                            String(
                                localized: "Remote helper installation cancelled",
                                comment: "Remote helper installation cancellation accessibility status")
                        )
                    }
                    return
                }

                let proposedDirectory = "~/.awesomux/handoffs/\(authority.terminalSessionID.rawValue)/"
                guard
                    await RemoteHandoff.confirmationProvider(
                        authority.remote,
                        source.displayName,
                        proposedDirectory,
                        originatingWindow
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
                RemoteHandoff.failurePresenter(failure, originatingWindow)
            } catch let failure as RemoteHelperInstaller.Failure {
                guard !Task.isCancelled else { return }
                RemoteHelperInstaller.presentFailure(failure, window: originatingWindow)
            } catch {
                guard !Task.isCancelled else { return }
                RemoteHandoff.failurePresenter(.transferFailed, originatingWindow)
            }
        }
    }
}
