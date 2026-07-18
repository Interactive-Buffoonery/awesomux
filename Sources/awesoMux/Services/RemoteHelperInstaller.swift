import AppKit
import AwesoMuxCore
import CryptoKit
import Darwin
import Foundation
import UnicodeHygiene

enum RemoteHelperInstaller {
    static let helperName = "awesoMuxBridgeHelper"
    static let remoteRelativePath = "~/.awesomux/bin/awesomux-bridge-helper"
    static let maximumHelperByteCount = 50 * 1024 * 1024
    static let maximumOutputByteCount = 4 * 1024
    static let successToken = "AWESOMUX_HELPER_INSTALLED"

    enum Failure: Error, Equatable, Sendable {
        case unsupportedPlatform
        case bundledHelperUnavailable
        case installationFailed
        case installedHelperIncompatible
    }

    struct Platform: Equatable, Sendable {
        let macOSMajorVersion: Int
        let architecture: String
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

    static func prepareBundledHelper(at url: URL) throws -> PreparedHelper {
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

    static func probePlatform(
        remote: RemoteTarget,
        controlPath: String,
        executableURL: URL = URL(fileURLWithPath: "/usr/bin/ssh"),
        timeout: DispatchTimeInterval = .seconds(15)
    ) async throws -> Platform {
        let output: Data
        do {
            output = try await BoundedProcessRunner.run(
                executableURL: executableURL,
                arguments: sshArguments(
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
        } catch {
            throw Failure.unsupportedPlatform
        }
        guard let platform = supportedPlatform(from: output) else {
            throw Failure.unsupportedPlatform
        }
        return platform
    }

    static func supportedPlatform(from output: Data) -> Platform? {
        let lines = String(decoding: output, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.count == 3,
            lines[0] == "Darwin",
            let major = Int(lines[1].split(separator: ".", maxSplits: 1).first ?? ""),
            major >= 15,
            lines[2] == "arm64"
        else {
            return nil
        }
        return Platform(macOSMajorVersion: major, architecture: lines[2])
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
                arguments: sshArguments(
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
        guard response == successToken || response == successToken + "\n" else {
            throw Failure.installationFailed
        }
    }

    static let platformProbeCommand =
        "/bin/sh -c "
        + shellQuote(
            "/usr/bin/uname -s && /usr/bin/sw_vers -productVersion && /usr/bin/uname -m"
        )

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
        let home = shellQuote(remoteHome)
        let awesomuxDirectory = shellQuote(remoteHome + "/.awesomux")
        let binDirectory = shellQuote(remoteHome + "/.awesomux/bin")
        let destination = shellQuote(remoteHome + "/.awesomux/bin/awesomux-bridge-helper")
        let temporaryTemplate = shellQuote(remoteHome + "/.awesomux/bin/.helper.XXXXXXXX")
        return [
            "umask 077",
            "home=\(home)",
            "awesomux_dir=\(awesomuxDirectory)",
            "bin_dir=\(binDirectory)",
            "destination=\(destination)",
            "uid=$(/usr/bin/id -u) || exit 1",
            "[ -d \"$home\" ] && [ ! -L \"$home\" ] || exit 1",
            "[ \"$(/usr/bin/stat -f '%u' \"$home\")\" = \"$uid\" ] || exit 1",
            "ensure_private_dir() { dir=$1; if [ -e \"$dir\" ] || [ -L \"$dir\" ]; then [ ! -L \"$dir\" ] && [ -d \"$dir\" ] || exit 1; else /bin/mkdir -m 700 \"$dir\" || exit 1; fi; [ \"$(/usr/bin/stat -f '%u' \"$dir\")\" = \"$uid\" ] && [ \"$(/usr/bin/stat -f '%Lp' \"$dir\")\" = 700 ] || exit 1; }",
            "ensure_private_dir \"$awesomux_dir\"",
            "ensure_private_dir \"$bin_dir\"",
            "if [ -e \"$destination\" ] || [ -L \"$destination\" ]; then [ ! -L \"$destination\" ] && [ -f \"$destination\" ] && [ \"$(/usr/bin/stat -f '%u' \"$destination\")\" = \"$uid\" ] || exit 1; fi",
            "tmp=$(/usr/bin/mktemp \(temporaryTemplate)) || exit 1",
            "trap '/bin/rm -f \"$tmp\"' EXIT",
            "trap 'exit 1' HUP INT TERM",
            "/bin/chmod 700 \"$tmp\" || exit 1",
            "/bin/cat > \"$tmp\" || exit 1",
            "[ \"$(/usr/bin/stat -f '%z' \"$tmp\")\" = \(expectedBytes) ] || exit 1",
            "actual=$(/usr/bin/shasum -a 256 \"$tmp\") || exit 1",
            "[ \"${actual%% *}\" = \(shellQuote(sha256)) ] || exit 1",
            "version=$(\"$tmp\" --version 2>/dev/null) || exit 1",
            "printf '%s\\n' \"$version\" | /usr/bin/grep -Fqx 'awesomux-bridge-v1' || exit 1",
            "printf '%s\\n' \"$version\" | /usr/bin/grep -Fqx 'awesomux-handoff-v1' || exit 1",
            "/bin/mv -f \"$tmp\" \"$destination\" || exit 1",
            "trap - EXIT HUP INT TERM",
            "printf '%s\\n' \(shellQuote(successToken))",
        ].joined(separator: "; ")
    }

    @MainActor
    static var confirmationProvider: @MainActor (_ remote: RemoteTarget, _ window: NSWindow?) async -> Bool = presentConfirmation

    @MainActor
    static var failurePresenter: @MainActor (Failure, NSWindow?) -> Void = presentFailure

    @MainActor
    static var successPresenter: @MainActor (NSWindow?) -> Void = presentSuccess

    @MainActor
    private static func presentConfirmation(remote: RemoteTarget, window: NSWindow?) async -> Bool {
        guard let window else { return false }
        let alert = NSAlert()
        alert.messageText = String(localized: "Install awesoMux Remote Helper?", comment: "Remote helper installation title")
        alert.informativeText = String(
            localized:
                "File transfer to \(remote.sshDestination) requires a small helper. awesoMux will install it for your account at \(remoteRelativePath). It receives only files you explicitly approve and does not require administrator access.",
            comment: "Remote helper installation explanation. Arguments are the declared SSH destination and fixed remote path."
        )
        alert.addButton(withTitle: String(localized: "Install Helper", comment: "Approve remote helper installation button"))
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
    private static func presentFailure(_ failure: Failure, window: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        switch failure {
        case .unsupportedPlatform:
            alert.messageText = String(
                localized: "Remote helper installation is unavailable", comment: "Unsupported remote helper platform title")
            alert.informativeText = String(
                localized: "This version of the awesoMux helper requires a compatible macOS destination.",
                comment: "Unsupported remote helper platform explanation")
        case .bundledHelperUnavailable:
            alert.messageText = String(localized: "The bundled remote helper is unavailable", comment: "Bundled helper unavailable title")
        case .installationFailed:
            alert.messageText = String(localized: "Remote helper installation failed", comment: "Remote helper installation failure title")
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
