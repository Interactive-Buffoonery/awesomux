import AppKit
import AwesoMuxCore
import CryptoKit
import Darwin
import Foundation
import UnicodeHygiene

enum RemoteHelperInstaller {
    static let helperName = "awesoMuxBridgeHelper"
    static let remoteRelativePath = BridgeAttachDecision.helperPath(remoteHome: "~")
    static let maximumHelperByteCount = 50 * 1024 * 1024
    static let maximumOutputByteCount = 4 * 1024
    static let successToken = "AWESOMUX_HELPER_INSTALLED"
    static let unsafeRemoteLayoutToken = "AWESOMUX_HELPER_UNSAFE_REMOTE_LAYOUT"
    static let requiredProtocols = [AmxBackend.bridgeProtocolVersion, "awesomux-handoff-v1"]

    enum Failure: Error, Equatable, Sendable {
        case helperProbeFailed
        case unsupportedPlatform
        case platformProbeFailed
        case bundledHelperUnavailable
        case unsafeRemoteLayout
        case installationFailed
        case verificationFailed
        case installedHelperIncompatible
    }

    enum Capability: Equatable, Sendable {
        case supported
        case missing
        case incompatible
        case probeFailed

        var approvalAction: ApprovalAction? {
            switch self {
            case .missing:
                .install
            case .incompatible:
                .update
            case .supported, .probeFailed:
                nil
            }
        }
    }

    enum ApprovalAction: Equatable, Sendable {
        case install
        case update
    }

    enum WorkflowOutcome: Equatable, Sendable {
        case cancelled
        case installed
    }

    struct PreparedHelper: Sendable {
        let url: URL
        let snapshot: RemoteHandoff.SourceSnapshot
        let sha256: String

        var byteCount: Int { snapshot.size }

        func openValidated() throws -> Int32 {
            let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw Failure.bundledHelperUnavailable }
            var status = stat()
            guard fstat(descriptor, &status) == 0,
                (status.st_mode & S_IFMT) == S_IFREG,
                RemoteHandoff.SourceSnapshot(status) == snapshot
            else {
                close(descriptor)
                throw Failure.bundledHelperUnavailable
            }
            return descriptor
        }
    }

    static func bundledHelperURL(
        executableURL: URL? = Bundle.main.executableURL
    ) -> URL? {
        executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent(helperName)
    }

    static func prepareBundledHelper(at url: URL) async throws -> PreparedHelper {
        let preparation = Task.detached(priority: .userInitiated) {
            try prepareBundledHelperSynchronously(at: url)
        }
        return try await withTaskCancellationHandler {
            try await preparation.value
        } onCancel: {
            preparation.cancel()
        }
    }

    private static func prepareBundledHelperSynchronously(at url: URL) throws -> PreparedHelper {
        var status = stat()
        guard url.isFileURL,
            url.path.hasPrefix("/"),
            lstat(url.path, &status) == 0,
            (status.st_mode & S_IFMT) == S_IFREG,
            status.st_size > 0,
            status.st_size <= off_t(maximumHelperByteCount),
            status.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH) != 0,
            let snapshot = RemoteHandoff.SourceSnapshot(status)
        else {
            throw Failure.bundledHelperUnavailable
        }

        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure.bundledHelperUnavailable }
        defer { close(descriptor) }

        var hasher = SHA256()
        var offset = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while offset < snapshot.size {
            try Task.checkCancellation()
            let amount = min(buffer.count, snapshot.size - offset)
            let bytesRead = buffer.withUnsafeMutableBytes {
                pread(descriptor, $0.baseAddress, amount, off_t(offset))
            }
            if bytesRead < 0, errno == EINTR { continue }
            guard bytesRead > 0 else { throw Failure.bundledHelperUnavailable }
            hasher.update(data: Data(buffer.prefix(bytesRead)))
            offset += bytesRead
        }

        var finalStatus = stat()
        guard fstat(descriptor, &finalStatus) == 0,
            RemoteHandoff.SourceSnapshot(finalStatus) == snapshot
        else {
            throw Failure.bundledHelperUnavailable
        }

        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return PreparedHelper(url: url, snapshot: snapshot, sha256: digest)
    }

    static func capability(
        remote: RemoteTarget,
        controlPath: String,
        helperPath: String,
        execChannel: @escaping BridgeDoctorSignals.ExecChannel = { command, stdin in
            try await BridgeExecChannel.run(command: command, stdin: stdin)
        }
    ) async throws -> Capability {
        let command = AmxBackend.bridgeHelperVersionCommand(
            controlPath: controlPath,
            remote: remote,
            helperPath: helperPath
        )
        let data: Data
        do {
            data = try await execChannel(command, nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as BoundedProcessRunner.ExecError {
            switch error {
            case .nonzeroExit(127):
                return .missing
            case .nonzeroExit(255), .spawnFailed, .timedOut, .outputTooLarge, .inputFailed:
                return .probeFailed
            case .nonzeroExit:
                return .incompatible
            }
        } catch {
            return .probeFailed
        }

        let output = String(decoding: data, as: UTF8.self)
        let required = Set(requiredProtocols)
        let compatible = BridgeDoctorSignals.compatibleProtocols(
            helperVersionOutput: output,
            appSupported: required
        )
        return compatible == required ? .supported : .incompatible
    }

    static func probePlatform(
        remote: RemoteTarget,
        controlPath: String,
        executableURL: URL = URL(fileURLWithPath: "/usr/bin/ssh"),
        timeout: DispatchTimeInterval = .seconds(15)
    ) async throws {
        let output: Data
        do {
            output = try await BoundedProcessRunner.run(
                executableURL: executableURL,
                arguments: RemoteHandoff.sshArguments(
                    remote: remote,
                    controlPath: controlPath,
                    remoteCommand: platformProbeCommand
                ),
                input: .data(Data()),
                maximumOutputByteCount: maximumOutputByteCount,
                timeout: timeout
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as BoundedProcessRunner.ExecError {
            if case .nonzeroExit(let status) = error, status != 255 {
                throw Failure.unsupportedPlatform
            }
            throw Failure.platformProbeFailed
        } catch {
            throw Failure.platformProbeFailed
        }
        guard isSupportedPlatform(output) else {
            throw Failure.unsupportedPlatform
        }
    }

    static func isSupportedPlatform(_ output: Data) -> Bool {
        let lines = String(decoding: output, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.count == 3,
            lines[0] == "Darwin",
            let major = Int(lines[1].split(separator: ".", maxSplits: 1).first ?? ""),
            major >= 15,
            lines[2] == "arm64"
        else {
            return false
        }
        return true
    }

    static func install(
        helper: PreparedHelper,
        remote: RemoteTarget,
        controlPath: String,
        remoteHome: String,
        executableURL: URL = URL(fileURLWithPath: "/usr/bin/ssh"),
        timeout: DispatchTimeInterval = .seconds(90)
    ) async throws {
        guard remoteHome.hasPrefix("/"),
            !UnicodeHygiene.containsUnsafePathScalars(remoteHome),
            (1...maximumHelperByteCount).contains(helper.byteCount),
            helper.sha256.count == 64,
            helper.sha256.unicodeScalars.allSatisfy({
                (0x30...0x39).contains($0.value) || (0x61...0x66).contains($0.value)
            })
        else {
            throw Failure.installationFailed
        }

        let descriptor = try helper.openValidated()
        defer { close(descriptor) }

        let output: Data
        do {
            output = try await BoundedProcessRunner.run(
                executableURL: executableURL,
                arguments: RemoteHandoff.sshArguments(
                    remote: remote,
                    controlPath: controlPath,
                    remoteCommand: bootstrapCommand(
                        remoteHome: remoteHome,
                        expectedBytes: helper.byteCount,
                        sha256: helper.sha256
                    )
                ),
                input: .descriptor(descriptor, byteCount: helper.byteCount),
                maximumOutputByteCount: maximumOutputByteCount,
                timeout: timeout
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Failure.installationFailed
        }

        let response = String(decoding: output, as: UTF8.self)
        if response == successToken || response == successToken + "\n" {
            return
        }
        if response == unsafeRemoteLayoutToken || response == unsafeRemoteLayoutToken + "\n" {
            throw Failure.unsafeRemoteLayout
        }
        throw Failure.installationFailed
    }

    static let platformProbeCommand =
        "/bin/sh -c "
        + shellQuote(
            "/usr/bin/uname -s && /usr/bin/sw_vers -productVersion && /usr/bin/uname -m"
        )

    static func bootstrapCommand(
        remoteHome: String,
        expectedBytes: Int,
        sha256: String
    ) -> String {
        "/bin/sh -c "
            + shellQuote(
                bootstrapScript(
                    remoteHome: remoteHome,
                    expectedBytes: expectedBytes,
                    sha256: sha256
                )
            )
    }

    static func bootstrapScript(
        remoteHome: String,
        expectedBytes: Int,
        sha256: String
    ) -> String {
        let destinationPath = BridgeAttachDecision.helperPath(remoteHome: remoteHome)
        let binDirectoryPath = (destinationPath as NSString).deletingLastPathComponent
        let awesomuxDirectoryPath = (binDirectoryPath as NSString).deletingLastPathComponent
        let home = shellQuote(remoteHome)
        let awesomuxDirectory = shellQuote(awesomuxDirectoryPath)
        let binDirectory = shellQuote(binDirectoryPath)
        let destination = shellQuote(destinationPath)
        let temporaryTemplate = shellQuote(binDirectoryPath + "/.helper.XXXXXXXX")
        var commands = [
            "umask 077",
            "home=\(home)",
            "awesomux_dir=\(awesomuxDirectory)",
            "bin_dir=\(binDirectory)",
            "destination=\(destination)",
            "fail_unsafe_layout() { /bin/cat >/dev/null; printf '%s\\n' \(shellQuote(unsafeRemoteLayoutToken)); exit 0; }",
            "uid=$(/usr/bin/id -u) || exit 1",
            "[ -d \"$home\" ] && [ ! -L \"$home\" ] || fail_unsafe_layout",
            "[ \"$(/usr/bin/stat -f '%u' \"$home\")\" = \"$uid\" ] || fail_unsafe_layout",
            "ensure_private_dir() { dir=$1; if [ -e \"$dir\" ] || [ -L \"$dir\" ]; then [ ! -L \"$dir\" ] && [ -d \"$dir\" ] || fail_unsafe_layout; else /bin/mkdir -m 700 \"$dir\" || exit 1; fi; [ \"$(/usr/bin/stat -f '%u' \"$dir\")\" = \"$uid\" ] && [ \"$(/usr/bin/stat -f '%Lp' \"$dir\")\" = 700 ] || fail_unsafe_layout; }",
            "ensure_private_dir \"$awesomux_dir\"",
            "ensure_private_dir \"$bin_dir\"",
            "if [ -e \"$destination\" ] || [ -L \"$destination\" ]; then [ ! -L \"$destination\" ] && [ -f \"$destination\" ] && [ \"$(/usr/bin/stat -f '%u' \"$destination\")\" = \"$uid\" ] || fail_unsafe_layout; fi",
            "tmp=$(/usr/bin/mktemp \(temporaryTemplate)) || exit 1",
            "trap '/bin/rm -f \"$tmp\"' EXIT",
            "trap 'exit 1' HUP INT TERM",
            "/bin/chmod 700 \"$tmp\" || exit 1",
            "/bin/cat > \"$tmp\" || exit 1",
            "[ \"$(/usr/bin/stat -f '%z' \"$tmp\")\" = \(expectedBytes) ] || exit 1",
            "actual=$(/usr/bin/shasum -a 256 \"$tmp\") || exit 1",
            "[ \"${actual%% *}\" = \(shellQuote(sha256)) ] || exit 1",
            "version=$(\"$tmp\" --version 2>/dev/null) || exit 1",
        ]
        commands.append(
            contentsOf: requiredProtocols.map {
                "printf '%s\\n' \"$version\" | /usr/bin/grep -Fqx \(shellQuote($0)) || exit 1"
            })
        commands.append(contentsOf: [
            "/bin/mv -f \"$tmp\" \"$destination\" || exit 1",
            "trap - EXIT HUP INT TERM",
            "printf '%s\\n' \(shellQuote(successToken))",
        ])
        return commands.joined(separator: "; ")
    }

    @MainActor
    static func performApprovedInstallation(
        helper: PreparedHelper,
        action: ApprovalAction,
        remote: RemoteTarget,
        controlPath: String,
        remoteHome: String,
        helperPath: String,
        window: NSWindow?,
        authorityIsCurrent: @escaping @MainActor () -> Bool,
        confirmation: @escaping @MainActor (ApprovalAction, RemoteTarget, NSWindow?) async -> Bool = {
            action, remote, window in
            await presentConfirmation(action: action, remote: remote, window: window)
        },
        installOperation: @escaping @MainActor (PreparedHelper, RemoteTarget, String, String) async throws -> Void = {
            helper, remote, controlPath, remoteHome in
            try await install(
                helper: helper,
                remote: remote,
                controlPath: controlPath,
                remoteHome: remoteHome
            )
        },
        capabilityProbe: @escaping @MainActor (RemoteTarget, String, String) async throws -> Capability = {
            remote, controlPath, helperPath in
            try await capability(
                remote: remote,
                controlPath: controlPath,
                helperPath: helperPath
            )
        },
        successPresentation: @escaping @MainActor (NSWindow?) -> Void = { window in
            presentSuccess(window: window)
        }
    ) async throws -> WorkflowOutcome {
        guard authorityIsCurrent() else {
            throw RemoteHandoff.Failure.destinationChanged
        }
        guard await confirmation(action, remote, window) else {
            return .cancelled
        }
        try Task.checkCancellation()
        guard authorityIsCurrent() else {
            throw RemoteHandoff.Failure.destinationChanged
        }

        try await installOperation(helper, remote, controlPath, remoteHome)
        try Task.checkCancellation()
        switch try await capabilityProbe(remote, controlPath, helperPath) {
        case .supported:
            break
        case .probeFailed:
            throw Failure.verificationFailed
        case .missing, .incompatible:
            throw Failure.installedHelperIncompatible
        }
        guard authorityIsCurrent() else {
            throw RemoteHandoff.Failure.destinationChanged
        }
        successPresentation(window)
        return .installed
    }

    @MainActor
    private static func presentConfirmation(
        action: ApprovalAction,
        remote: RemoteTarget,
        window: NSWindow?
    ) async -> Bool {
        guard let window else { return false }
        let alert = NSAlert()
        switch action {
        case .install:
            alert.messageText = String(localized: "Install awesoMux Remote Helper?", comment: "Remote helper installation title")
            alert.informativeText = String(
                localized:
                    "File transfer to \(remote.sshDestination) requires a small helper. awesoMux will install it for your account at \(remoteRelativePath). It receives only files you explicitly approve and does not require administrator access.",
                comment: "Remote helper installation explanation. Arguments are the declared SSH destination and fixed remote path."
            )
            alert.addButton(withTitle: String(localized: "Install Helper", comment: "Approve remote helper installation button"))
        case .update:
            alert.messageText = String(localized: "Update awesoMux Remote Helper?", comment: "Remote helper update title")
            alert.informativeText = String(
                localized:
                    "The helper at \(remoteRelativePath) on \(remote.sshDestination) is incompatible. awesoMux will replace it for your account. It receives only files you explicitly approve and does not require administrator access.",
                comment: "Remote helper update explanation. Arguments are the fixed remote path and declared SSH destination."
            )
            alert.addButton(withTitle: String(localized: "Update Helper", comment: "Approve remote helper update button"))
        }
        alert.addButton(withTitle: String(localized: "Not Now", comment: "Decline remote helper installation button"))
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
    static func presentFailure(_ failure: Failure, window: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        switch failure {
        case .helperProbeFailed:
            alert.messageText = String(localized: "Could not check the remote helper", comment: "Remote helper probe failure title")
            alert.informativeText = String(
                localized: "Check the SSH connection and try the file transfer again.",
                comment: "Remote helper probe failure recovery")
        case .unsupportedPlatform:
            alert.messageText = String(
                localized: "Remote helper installation is unavailable", comment: "Unsupported remote helper platform title")
            alert.informativeText = String(
                localized: "The bundled helper requires an Apple Silicon destination running macOS 15 or later.",
                comment: "Unsupported remote helper platform explanation")
        case .platformProbeFailed:
            alert.messageText = String(localized: "Could not check the remote platform", comment: "Remote platform probe failure title")
            alert.informativeText = String(
                localized: "Check the SSH connection and try the installation again.",
                comment: "Remote platform probe failure recovery")
        case .bundledHelperUnavailable:
            alert.messageText = String(localized: "The bundled remote helper is unavailable", comment: "Bundled helper unavailable title")
        case .unsafeRemoteLayout:
            alert.messageText = String(localized: "The remote helper folder is not private", comment: "Unsafe remote helper layout title")
            alert.informativeText = String(
                localized:
                    "The existing ~/.awesomux and ~/.awesomux/bin paths must be regular folders owned by your remote account with permissions 700.",
                comment: "Unsafe remote helper layout recovery instructions")
        case .installationFailed:
            alert.messageText = String(localized: "Remote helper installation failed", comment: "Remote helper installation failure title")
        case .verificationFailed:
            alert.messageText = String(
                localized: "Could not verify the installed remote helper", comment: "Installed helper verification transport failure title")
            alert.informativeText = String(
                localized: "Check the SSH connection and try the file transfer again.",
                comment: "Installed helper verification transport failure recovery")
        case .installedHelperIncompatible:
            alert.messageText = String(
                localized: "The installed remote helper is incompatible", comment: "Installed helper verification failure title")
        }
        alert.addButton(withTitle: String(localized: "OK", comment: "Dismiss remote helper installation result"))
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    @MainActor
    private static func presentSuccess(window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Remote helper installed", comment: "Remote helper installation success title")
        alert.informativeText = String(
            localized: "Paste the file again to continue the transfer.", comment: "Remote helper installation retry instruction")
        alert.addButton(withTitle: String(localized: "OK", comment: "Dismiss remote helper installation success"))
        TerminalAccessibilityAnnouncer.announce(
            String(localized: "Remote helper installed", comment: "Remote helper installation success accessibility status")
        )
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
