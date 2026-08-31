import AppKit
import AwesoMuxCore
import CryptoKit
import Darwin
import Foundation
import UnicodeHygiene

enum RemoteHelperInstaller {
    static let helperName = "awesoMuxBridgeHelper"
    static let remoteRelativePath = BridgeAttachDecision.helperPath(remoteHome: "~")
    static let maximumHelperByteCount = 200 * 1024 * 1024
    static let maximumOutputByteCount = 4 * 1024
    static let successToken = "AWESOMUX_HELPER_INSTALLED"
    static let unsafeRemoteLayoutToken = "AWESOMUX_HELPER_UNSAFE_REMOTE_LAYOUT"
    static let bridgeRequiredProtocols = [AmxBackend.bridgeProtocolVersion]
    static let handoffRequiredProtocols = ["awesomux-handoff-v1"]
    static let livenessRequiredProtocols = ["awesomux-liveness-v1"]
    static let requiredProtocols = bridgeRequiredProtocols + handoffRequiredProtocols

    enum Failure: Error, Equatable, Sendable {
        case helperProbeFailed
        case unsupportedPlatform
        case platformProbeFailed
        case bundledHelperUnavailable
        case unsafeRemoteLayout
        case installationFailed
        case verificationFailed
        case installedHelperIncompatible
        case releaseArtifactUnavailable
        case releaseArtifactChecksumMismatch
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

    enum Platform: Equatable, Sendable {
        case macOSArm64
        case linux(LinuxArchitecture)
    }

    enum LinuxArchitecture: String, Equatable, Sendable {
        case aarch64
        case x86_64
    }

    struct FeatureCapabilities: Equatable, Sendable {
        let bridge: Bool
        let handoff: Bool
        let liveness: Bool

        init(protocols: Set<String>) {
            bridge = Set(bridgeRequiredProtocols).isSubset(of: protocols)
            handoff = Set(handoffRequiredProtocols).isSubset(of: protocols)
            liveness = Set(livenessRequiredProtocols).isSubset(of: protocols)
        }
    }

    static func featureCapabilities(helperVersionOutput: String) -> FeatureCapabilities {
        FeatureCapabilities(
            protocols: BridgeDoctorSignals.compatibleProtocols(
                helperVersionOutput: helperVersionOutput,
                appSupported: Set(requiredProtocols + livenessRequiredProtocols)
            )
        )
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

    struct AcquiredHelper: Sendable {
        let prepared: PreparedHelper
        let cleanupDirectory: URL?

        func cleanup(fileManager: FileManager = .default) {
            guard let cleanupDirectory else { return }
            try? fileManager.removeItem(at: cleanupDirectory)
        }
    }

    struct ReleaseArtifact: Equatable, Sendable {
        let binaryURL: URL
        let checksumURL: URL
        let filename: String
    }

    typealias DataDownload = @Sendable (URL) async throws -> Data
    typealias FileDownload = @Sendable (URL) async throws -> URL

    static func releaseArtifact(
        version: String,
        architecture: LinuxArchitecture
    ) -> ReleaseArtifact? {
        let components = version.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3,
            components.allSatisfy({
                !$0.isEmpty && $0.utf8.allSatisfy { (0x30...0x39).contains($0) }
            })
        else {
            return nil
        }
        let filename = "awesomux-bridge-helper-linux-\(architecture.rawValue)"
        guard
            let binaryURL = URL(
                string: "https://github.com/Interactive-Buffoonery/awesomux/releases/download/v\(version)/\(filename)"
            )
        else {
            return nil
        }
        return ReleaseArtifact(
            binaryURL: binaryURL,
            checksumURL: binaryURL.appendingPathExtension("sha256"),
            filename: filename
        )
    }

    static func parseReleaseChecksum(_ data: Data, expectedFilename: String) -> String? {
        guard data.count <= 4 * 1024,
            let line = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !line.contains("\n"),
            !line.contains("\r")
        else {
            return nil
        }
        let fields = line.split(whereSeparator: \.isWhitespace)
        guard fields.count == 2 else { return nil }
        let digest = String(fields[0])
        let filename = String(fields[1]).trimmingPrefix("*")
        guard filename == expectedFilename,
            digest.count == 64,
            digest.unicodeScalars.allSatisfy({
                (0x30...0x39).contains($0.value) || (0x61...0x66).contains($0.value)
            })
        else {
            return nil
        }
        return digest
    }

    static func acquireHelper(
        for platform: Platform,
        version: String,
        executableURL: URL? = Bundle.main.executableURL,
        dataDownload: @escaping DataDownload = downloadData,
        fileDownload: @escaping FileDownload = downloadFile,
        fileManager: FileManager = .default
    ) async throws -> AcquiredHelper {
        switch platform {
        case .macOSArm64:
            guard let url = bundledHelperURL(executableURL: executableURL) else {
                throw Failure.bundledHelperUnavailable
            }
            return AcquiredHelper(
                prepared: try await prepareBundledHelper(at: url),
                cleanupDirectory: nil
            )
        case .linux(let architecture):
            guard let artifact = releaseArtifact(version: version, architecture: architecture) else {
                throw Failure.releaseArtifactUnavailable
            }
            let checksumData: Data
            let downloadedURL: URL
            do {
                async let checksum = dataDownload(artifact.checksumURL)
                async let binary = fileDownload(artifact.binaryURL)
                (checksumData, downloadedURL) = try await (checksum, binary)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw Failure.releaseArtifactUnavailable
            }
            guard
                let expectedDigest = parseReleaseChecksum(
                    checksumData,
                    expectedFilename: artifact.filename
                )
            else {
                try? fileManager.removeItem(at: downloadedURL)
                throw Failure.releaseArtifactChecksumMismatch
            }

            let directory = fileManager.temporaryDirectory
                .appendingPathComponent("awesomux-linux-helper-\(UUID().uuidString)", isDirectory: true)
            do {
                try fileManager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
                let localURL = directory.appendingPathComponent(artifact.filename)
                try fileManager.moveItem(at: downloadedURL, to: localURL)
                try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: localURL.path)
                let prepared = try await prepareBundledHelper(at: localURL)
                guard prepared.sha256 == expectedDigest else {
                    throw Failure.releaseArtifactChecksumMismatch
                }
                return AcquiredHelper(prepared: prepared, cleanupDirectory: directory)
            } catch is CancellationError {
                try? fileManager.removeItem(at: directory)
                try? fileManager.removeItem(at: downloadedURL)
                throw CancellationError()
            } catch let failure as Failure {
                try? fileManager.removeItem(at: directory)
                try? fileManager.removeItem(at: downloadedURL)
                throw failure
            } catch {
                try? fileManager.removeItem(at: directory)
                try? fileManager.removeItem(at: downloadedURL)
                throw Failure.releaseArtifactUnavailable
            }
        }
    }

    private static func downloadData(from url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw Failure.releaseArtifactUnavailable
        }
        return data
    }

    private static func downloadFile(from url: URL) async throws -> URL {
        let (temporaryURL, response) = try await URLSession.shared.download(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw Failure.releaseArtifactUnavailable
        }
        return temporaryURL
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
        requiredProtocols: [String] = requiredProtocols,
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
        let compatible = BridgeDoctorSignals.compatibleProtocols(
            helperVersionOutput: output,
            appSupported: Set(Self.requiredProtocols + livenessRequiredProtocols)
        )
        return Set(requiredProtocols).isSubset(of: compatible) ? .supported : .incompatible
    }

    static func additionalSSHCapability(
        remote: RemoteTarget,
        controlPath: String,
        helperPath: String,
        execChannel: @escaping BridgeDoctorSignals.ExecChannel = { command, stdin in
            try await BridgeExecChannel.run(command: command, stdin: stdin)
        }
    ) async throws -> Capability {
        try await capability(
            remote: remote,
            controlPath: controlPath,
            helperPath: helperPath,
            requiredProtocols: requiredProtocols + livenessRequiredProtocols,
            execChannel: execChannel
        )
    }

    static func probePlatform(
        remote: RemoteTarget,
        controlPath: String,
        executableURL: URL = URL(fileURLWithPath: "/usr/bin/ssh"),
        timeout: Duration = .seconds(15)
    ) async throws -> Platform {
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
        guard let platform = supportedPlatform(output) else {
            throw Failure.unsupportedPlatform
        }
        return platform
    }

    static func isSupportedPlatform(_ output: Data) -> Bool {
        supportedPlatform(output) != nil
    }

    static func supportedPlatform(_ output: Data) -> Platform? {
        let lines = String(decoding: output, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.count == 3 else { return nil }
        switch lines[0] {
        case "Darwin":
            guard let major = Int(lines[1].split(separator: ".", maxSplits: 1).first ?? ""),
                major >= 15,
                lines[2] == "arm64"
            else {
                return nil
            }
            return .macOSArm64
        case "Linux":
            guard let architecture = LinuxArchitecture(rawValue: lines[2]) else { return nil }
            return .linux(architecture)
        default:
            return nil
        }
    }

    static func install(
        helper: PreparedHelper,
        remote: RemoteTarget,
        controlPath: String,
        remoteHome: String,
        requiredProtocols: [String] = requiredProtocols,
        executableURL: URL = URL(fileURLWithPath: "/usr/bin/ssh"),
        timeout: Duration = .seconds(90)
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
                        sha256: helper.sha256,
                        requiredProtocols: requiredProtocols
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
            "kernel=$(/usr/bin/uname -s) || exit 1; printf '%s\\n' \"$kernel\"; if [ \"$kernel\" = Darwin ]; then /usr/bin/sw_vers -productVersion; else /usr/bin/uname -r; fi; /usr/bin/uname -m"
        )

    static func bootstrapCommand(
        remoteHome: String,
        expectedBytes: Int,
        sha256: String,
        requiredProtocols: [String] = requiredProtocols
    ) -> String {
        "/bin/sh -c "
            + shellQuote(
                bootstrapScript(
                    remoteHome: remoteHome,
                    expectedBytes: expectedBytes,
                    sha256: sha256,
                    requiredProtocols: requiredProtocols
                )
            )
    }

    static func bootstrapScript(
        remoteHome: String,
        expectedBytes: Int,
        sha256: String,
        requiredProtocols: [String] = requiredProtocols
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
            "stat_owner() { /usr/bin/stat -f '%u' \"$1\" 2>/dev/null || /usr/bin/stat -c '%u' \"$1\" 2>/dev/null; }",
            "stat_mode() { /usr/bin/stat -f '%Lp' \"$1\" 2>/dev/null || /usr/bin/stat -c '%a' \"$1\" 2>/dev/null; }",
            "stat_size() { /usr/bin/stat -f '%z' \"$1\" 2>/dev/null || /usr/bin/stat -c '%s' \"$1\" 2>/dev/null; }",
            "[ -d \"$home\" ] && [ ! -L \"$home\" ] || fail_unsafe_layout",
            "[ \"$(stat_owner \"$home\")\" = \"$uid\" ] || fail_unsafe_layout",
            "ensure_private_dir() { dir=$1; if [ -e \"$dir\" ] || [ -L \"$dir\" ]; then [ ! -L \"$dir\" ] && [ -d \"$dir\" ] || fail_unsafe_layout; else /bin/mkdir -m 700 \"$dir\" || exit 1; fi; [ \"$(stat_owner \"$dir\")\" = \"$uid\" ] && [ \"$(stat_mode \"$dir\")\" = 700 ] || fail_unsafe_layout; }",
            "ensure_private_dir \"$awesomux_dir\"",
            "ensure_private_dir \"$bin_dir\"",
            "if [ -e \"$destination\" ] || [ -L \"$destination\" ]; then [ ! -L \"$destination\" ] && [ -f \"$destination\" ] && [ \"$(stat_owner \"$destination\")\" = \"$uid\" ] || fail_unsafe_layout; fi",
            "tmp=$(/usr/bin/mktemp \(temporaryTemplate)) || exit 1",
            "trap '/bin/rm -f \"$tmp\"' EXIT",
            "trap 'exit 1' HUP INT TERM",
            "/bin/chmod 700 \"$tmp\" || exit 1",
            "/bin/cat > \"$tmp\" || exit 1",
            "[ \"$(stat_size \"$tmp\")\" = \(expectedBytes) ] || exit 1",
            "if [ -x /usr/bin/shasum ]; then actual=$(/usr/bin/shasum -a 256 \"$tmp\"); elif [ -x /usr/bin/sha256sum ]; then actual=$(/usr/bin/sha256sum \"$tmp\"); else exit 1; fi",
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
    static func offerAdditionalSSHFeatures(
        remote: RemoteTarget,
        controlPath: String,
        remoteHome: String,
        helperPath: String,
        window: NSWindow?,
        authorityIsCurrent: @escaping @MainActor () -> Bool
    ) async -> Bool {
        guard let window,
            await waitForSheetAvailability(
                authorityIsCurrent: authorityIsCurrent,
                hasAttachedSheet: { window.attachedSheet != nil }
            )
        else {
            return false
        }
        do {
            let capability = try await additionalSSHCapability(
                remote: remote,
                controlPath: controlPath,
                helperPath: helperPath
            )
            guard let action = capability.approvalAction else {
                return capability == .supported
            }
            let platform = try await probePlatform(remote: remote, controlPath: controlPath)
            guard authorityIsCurrent(),
                await presentAdditionalSSHConfirmation(
                    action: action,
                    remote: remote,
                    platform: platform
                )
            else {
                return false
            }
            try Task.checkCancellation()
            guard authorityIsCurrent() else { return false }

            let progress = presentInstallProgress(remote: remote, window: window)
            defer { progress.dismiss() }
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
            let acquired = try await acquireHelper(for: platform, version: version)
            defer { acquired.cleanup() }
            try await install(
                helper: acquired.prepared,
                remote: remote,
                controlPath: controlPath,
                remoteHome: remoteHome,
                requiredProtocols: requiredProtocols + livenessRequiredProtocols
            )
            try Task.checkCancellation()
            guard authorityIsCurrent() else { return false }
            guard
                try await additionalSSHCapability(
                    remote: remote,
                    controlPath: controlPath,
                    helperPath: helperPath
                ) == .supported
            else {
                throw Failure.installedHelperIncompatible
            }
            return true
        } catch is CancellationError {
            return false
        } catch let failure as Failure {
            presentFailure(failure, window: window)
            return false
        } catch {
            presentFailure(.installationFailed, window: window)
            return false
        }
    }

    @MainActor
    static func waitForSheetAvailability(
        authorityIsCurrent: @escaping @MainActor () -> Bool,
        hasAttachedSheet: @escaping @MainActor () -> Bool,
        pause: @escaping @MainActor () async throws -> Void = {
            try await Task.sleep(for: .milliseconds(50))
        }
    ) async -> Bool {
        for _ in 0..<40 {
            guard authorityIsCurrent() else {
                return false
            }
            guard hasAttachedSheet() else {
                return true
            }
            do {
                try await pause()
            } catch {
                return false
            }
        }
        return false
    }

    @MainActor
    private static func presentAdditionalSSHConfirmation(
        action: ApprovalAction,
        remote: RemoteTarget,
        platform: Platform
    ) async -> Bool {
        let platformName =
            switch platform {
            case .macOSArm64:
                "macOS · arm64"
            case .linux(let architecture):
                "Linux · \(architecture.rawValue)"
            }
        return await RemoteAdditionalSSHFeaturesSheetPresenter.shared.present(
            action: action == .install ? .install : .update,
            destination: remote.sshDestination,
            platform: platformName,
            installPath: remoteRelativePath
        )
    }

    @MainActor
    private static func presentInstallProgress(
        remote: RemoteTarget,
        window: NSWindow
    ) -> RemoteHelperInstallProgress {
        let alert = NSAlert()
        alert.messageText = String(
            localized: "Installing helper on \(remote.sshDestination)…",
            comment: "Remote helper installation progress title. Argument is the SSH destination."
        )
        alert.informativeText = String(
            localized: "Downloading, verifying, and installing the version matched to this copy of awesoMux.",
            comment: "Remote helper installation progress explanation")
        let indicator = NSProgressIndicator()
        indicator.style = .spinning
        indicator.controlSize = .small
        indicator.startAnimation(nil)
        alert.accessoryView = indicator
        let progressButton = alert.addButton(
            withTitle: String(localized: "Installing…", comment: "Remote helper installation progress button")
        )
        progressButton.isEnabled = false
        alert.beginSheetModal(for: window)
        return RemoteHelperInstallProgress(alert: alert, window: window)
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
        case .releaseArtifactUnavailable:
            alert.messageText = String(
                localized: "Could not download the remote helper", comment: "Remote helper release download failure title")
            alert.informativeText = String(
                localized: "Check your internet connection and try again.",
                comment: "Remote helper release download failure recovery")
        case .releaseArtifactChecksumMismatch:
            alert.messageText = String(
                localized: "The remote helper download could not be verified",
                comment: "Remote helper release checksum failure title")
            alert.informativeText = String(
                localized: "The downloaded file was not installed.",
                comment: "Remote helper release checksum failure recovery")
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

@MainActor
private final class RemoteHelperInstallProgress {
    private let alert: NSAlert
    private weak var window: NSWindow?

    init(alert: NSAlert, window: NSWindow) {
        self.alert = alert
        self.window = window
    }

    func dismiss() {
        guard let window, window.attachedSheet === alert.window else { return }
        window.endSheet(alert.window)
    }
}
