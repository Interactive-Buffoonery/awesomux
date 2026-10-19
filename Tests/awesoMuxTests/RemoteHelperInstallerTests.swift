import AppKit
import AwesoMuxConfig
import AwesoMuxCore
import AwesoMuxTestSupport
import Darwin
import Foundation
import Testing
@testable import awesoMux

@Suite("Remote helper installer", .serialized)
struct RemoteHelperInstallerTests {
    @Test("remote helper approval only asks under the default policy")
    @MainActor
    func helperApprovalPolicy() async {
        for policy in WorkspaceConfig.RemoteHelperInstallPolicy.allCases {
            for answer in [false, true] {
                var confirmations = 0
                let approved = await RemoteHelperInstaller.approveInstallation(policy: { policy }) {
                    confirmations += 1
                    return answer
                }
                #expect(confirmations == (policy == .ask ? 1 : 0))
                #expect(approved == (policy == .alwaysInstall || (policy == .ask && answer)))
            }
        }
        var policy = WorkspaceConfig.RemoteHelperInstallPolicy.ask
        let approved = await RemoteHelperInstaller.approveInstallation(policy: { policy }) {
            policy = .neverAsk
            return true
        }
        #expect(!approved)
    }

    @Test("remembered helper policy gates acquisition and rechecks before installation")
    @MainActor
    func rememberedPolicyGatesInstallation() async throws {
        let directory = try TemporaryDirectory(prefix: "helper-policy")
        let prepared = try await RemoteHelperInstaller.prepareBundledHelper(
            at: try helper(in: directory, payload: Data("helper".utf8))
        )
        let remote = try #require(RemoteTarget(parsing: "me@example"))
        for initialPolicy in [WorkspaceConfig.RemoteHelperInstallPolicy.neverAsk, .alwaysInstall] {
            for revokeDuringAcquisition in [false, true] {
                var policy = initialPolicy
                var events: [String] = []
                let result = try await RemoteHelperInstaller.performApprovedInstallation(
                    acquisition: {
                        events.append("acquire")
                        if revokeDuringAcquisition { policy = .neverAsk }
                        return .init(prepared: prepared, cleanupDirectory: nil)
                    },
                    action: .install,
                    remote: remote,
                    controlPath: "/tmp/control/%C",
                    remoteHome: "/home/me",
                    helperPath: "/home/me/.awesomux/bin/awesomux-bridge-helper",
                    window: nil,
                    authorityIsCurrent: { true },
                    policy: { policy },
                    confirmation: { _, _, _ in
                        events.append("confirmation")
                        return true
                    },
                    installOperation: { _, _, _, _ in events.append("install") },
                    capabilityProbe: { _, _, _ in
                        events.append("verify")
                        return .supported
                    },
                    successPresentation: { _ in events.append("success") }
                )
                if initialPolicy == .neverAsk {
                    #expect(result == .cancelled)
                    #expect(events.isEmpty)
                } else if revokeDuringAcquisition {
                    #expect(result == .cancelled)
                    #expect(events == ["acquire"])
                } else {
                    #expect(result == .installed)
                    #expect(events == ["acquire", "install", "verify", "success"])
                }
            }
        }
    }

    @Test("release artifact URLs are version-matched and architecture-specific")
    func releaseArtifactURL() throws {
        let artifact = try #require(
            RemoteHelperInstaller.releaseArtifact(version: "1.2.3", architecture: .aarch64)
        )
        #expect(
            artifact.binaryURL.absoluteString
                == "https://github.com/Interactive-Buffoonery/awesomux/releases/download/v1.2.3/awesomux-bridge-helper-linux-aarch64"
        )
        #expect(artifact.checksumURL.absoluteString == artifact.binaryURL.absoluteString + ".sha256")
        #expect(RemoteHelperInstaller.releaseArtifact(version: "1.2", architecture: .aarch64) == nil)
        #expect(RemoteHelperInstaller.releaseArtifact(version: "1.2.3-dev", architecture: .aarch64) == nil)
    }

    @Test("release checksum parser binds the digest to the expected filename")
    func releaseChecksumParser() {
        let digest = String(repeating: "a", count: 64)
        let filename = "awesomux-bridge-helper-linux-aarch64"
        #expect(
            RemoteHelperInstaller.parseReleaseChecksum(
                Data("\(digest)  \(filename)\n".utf8),
                expectedFilename: filename
            ) == digest
        )
        #expect(
            RemoteHelperInstaller.parseReleaseChecksum(
                Data("\(digest)  another-file\n".utf8),
                expectedFilename: filename
            ) == nil
        )
        #expect(
            RemoteHelperInstaller.parseReleaseChecksum(
                Data("\(digest)  \(filename)\nsecond line".utf8),
                expectedFilename: filename
            ) == nil
        )
    }

    @Test("Linux acquisition verifies the release checksum and yields private executable bytes")
    func linuxHelperAcquisition() async throws {
        let directory = try TemporaryDirectory(prefix: "helper-release-acquisition")
        let sourceURL = try helper(in: directory, payload: Data("linux helper".utf8))
        let preparedSource = try await RemoteHelperInstaller.prepareBundledHelper(at: sourceURL)
        let filename = "awesomux-bridge-helper-linux-aarch64"
        let checksum = Data("\(preparedSource.sha256)  \(filename)\n".utf8)

        let acquired = try await RemoteHelperInstaller.acquireHelper(
            for: .linux(.aarch64),
            version: "1.2.3",
            dataDownload: { _ in checksum },
            fileDownload: { _ in sourceURL }
        )
        defer { acquired.cleanup() }

        #expect(acquired.prepared.sha256 == preparedSource.sha256)
        #expect(acquired.prepared.byteCount == preparedSource.byteCount)
        var status = stat()
        #expect(lstat(acquired.prepared.url.path, &status) == 0)
        #expect(status.st_mode & 0o777 == 0o700)
    }

    @Test("bundled helper preparation rejects unsafe source types")
    func helperPreparationRejectsUnsafeSources() async throws {
        let directory = try TemporaryDirectory(prefix: "helper-installer-source-reject")
        let directoryURL = directory.url.appendingPathComponent("directory")
        let plainFile = directory.url.appendingPathComponent("plain")
        let symlink = directory.url.appendingPathComponent("symlink")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: false)
        try Data("x".utf8).write(to: plainFile)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: plainFile)

        for url in [directoryURL, plainFile, symlink] {
            await #expect(throws: RemoteHelperInstaller.Failure.bundledHelperUnavailable) {
                try await RemoteHelperInstaller.prepareBundledHelper(at: url)
            }
        }
    }

    @Test("source replacement after preparation is rejected")
    func helperReplacementIsRejected() async throws {
        let directory = try TemporaryDirectory(prefix: "helper-installer-replacement")
        let helperURL = try helper(in: directory, payload: Data("original".utf8))
        let prepared = try await RemoteHelperInstaller.prepareBundledHelper(at: helperURL)
        let replacement = directory.url.appendingPathComponent("replacement")
        try Data("replacement".utf8).write(to: replacement)
        guard chmod(replacement.path, 0o700) == 0 else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.moveItem(at: helperURL, to: directory.url.appendingPathComponent("old"))
        try FileManager.default.moveItem(at: replacement, to: helperURL)

        #expect(throws: RemoteHelperInstaller.Failure.bundledHelperUnavailable) {
            let descriptor = try prepared.openValidated()
            close(descriptor)
        }
    }

    @Test("platform gate identifies supported remote helper builds")
    func platformGate() {
        #expect(
            RemoteHelperInstaller.supportedPlatform(Data("Darwin\n15.0\narm64\n".utf8))
                == .macOSArm64)
        #expect(
            RemoteHelperInstaller.supportedPlatform(Data("Linux\n6.8\naarch64\n".utf8))
                == .linux(.aarch64))
        #expect(
            RemoteHelperInstaller.supportedPlatform(Data("Linux\n6.8\nx86_64\n".utf8))
                == .linux(.x86_64))
        for unsupported in [
            "Darwin\n14.7\narm64\n",
            "Darwin\n26.0\nx86_64\n",
            "Linux\n6.8\narmv7l\n",
            "Darwin\n26.0\narm64\nextra\n",
            "malformed",
        ] {
            #expect(RemoteHelperInstaller.supportedPlatform(Data(unsupported.utf8)) == nil)
        }
    }

    @Test(
        "capability gates distinguish supported, incompatible, missing and failed probes",
        arguments: [
            ("awesomux-handoff-v1\nawesomux-bridge-v1\n", Int32?.none, false, RemoteHelperInstaller.Capability.supported),
            ("awesomux-bridge-v1\n", nil, false, .incompatible),
            ("", 127, false, .missing), ("", 255, false, .probeFailed),
            ("awesomux-handoff-v1\nawesomux-bridge-v1\n", nil, true, .incompatible),
        ])
    func capabilityStates(output: String, status: Int32?, additional: Bool, expected: RemoteHelperInstaller.Capability) async throws {
        let remote = try #require(RemoteTarget(parsing: "me@example"))
        let exec: @Sendable (String, Data?) async throws -> Data = { _, _ in
            if let status { throw BoundedProcessRunner.ExecError.nonzeroExit(status) }
            return Data(output.utf8)
        }
        let result =
            try await additional
            ? RemoteHelperInstaller.additionalSSHCapability(
                remote: remote, controlPath: "/tmp/control/%C",
                helperPath: "/Users/me/.awesomux/bin/awesomux-bridge-helper", execChannel: exec)
            : RemoteHelperInstaller.capability(
                remote: remote, controlPath: "/tmp/control/%C",
                helperPath: "/Users/me/.awesomux/bin/awesomux-bridge-helper", execChannel: exec)
        #expect(result == expected)
        if expected == .incompatible { #expect(result.approvalAction == .update) }
        if expected == .missing { #expect(result.approvalAction == .install) }
    }

    @Test(
        "feature capabilities are independent",
        arguments: [
            ("awesomux-bridge-v1\nawesomux-handoff-v1\n", false),
            ("awesomux-bridge-v1\nawesomux-handoff-v1\nawesomux-liveness-v1\n", true),
        ])
    func featureCapabilitiesAreIndependent(output: String, liveness: Bool) {
        let capabilities = RemoteHelperInstaller.featureCapabilities(helperVersionOutput: output)
        #expect(capabilities.bridge && capabilities.handoff)
        #expect(capabilities.liveness == liveness)
    }

    @Test("installation streams only verified helper bytes and accepts the fixed success token")
    func installationStreamsHelper() async throws {
        let directory = try TemporaryDirectory(prefix: "helper-installer-transfer")
        let payload = Data("signed helper bytes".utf8)
        let helperURL = try helper(in: directory, payload: payload)
        let prepared = try await RemoteHelperInstaller.prepareBundledHelper(at: helperURL)
        let capturedInput = directory.url.appendingPathComponent("captured-input")
        let capturedArguments = directory.url.appendingPathComponent("captured-arguments")
        let executable = try shellScript(
            in: directory,
            body: """
                cat > \(shellQuote(capturedInput.path))
                printf '%s\\n' "$@" > \(shellQuote(capturedArguments.path))
                printf '%s\\n' '\(RemoteHelperInstaller.successToken)'
                """
        )
        let remote = try #require(RemoteTarget(parsing: "me@example"))

        try await RemoteHelperInstaller.install(
            helper: prepared,
            remote: remote,
            controlPath: "/tmp/control/%C",
            remoteHome: "/Users/me",
            executableURL: executable,
            timeout: .seconds(10)
        )

        #expect(try Data(contentsOf: capturedInput) == payload)
        let arguments = try String(contentsOf: capturedArguments, encoding: .utf8)
        #expect(arguments.contains("me@example"))
        #expect(!arguments.contains(helperURL.path))
    }

    @Test("bootstrap installs the helper privately and advertises both protocols")
    func bootstrapInstallsHelper() async throws {
        let directory = try TemporaryDirectory(prefix: "helper-installer-bootstrap")
        let helperPayload = Data(
            """
            #!/bin/sh
            if [ "$1" = "--version" ]; then
              printf '%s\\n' awesomux-bridge-v1 awesomux-handoff-v1
              exit 0
            fi
            exit 1
            """.utf8
        )
        let prepared = try await RemoteHelperInstaller.prepareBundledHelper(
            at: try helper(in: directory, payload: helperPayload)
        )
        let remoteHome = directory.url.appendingPathComponent("remote-home")
        try FileManager.default.createDirectory(at: remoteHome, withIntermediateDirectories: false)
        let executable = try passthroughSSH(in: directory)
        let remote = try #require(RemoteTarget(parsing: "me@example"))

        try await RemoteHelperInstaller.install(
            helper: prepared,
            remote: remote,
            controlPath: "/tmp/control/%C",
            remoteHome: remoteHome.path,
            executableURL: executable,
            timeout: .seconds(10)
        )

        let installed =
            remoteHome
            .appendingPathComponent(".awesomux/bin/awesomux-bridge-helper")
        #expect(try Data(contentsOf: installed) == helperPayload)
        var status = stat()
        #expect(lstat(installed.path, &status) == 0)
        #expect(status.st_mode & 0o777 == 0o700)
        let version = try await BoundedProcessRunner.run(
            executableURL: installed,
            arguments: ["--version"],
            input: .data(Data()),
            maximumOutputByteCount: 1024,
            timeout: realSpawnTimeout
        )
        #expect(String(decoding: version, as: UTF8.self).contains("awesomux-bridge-v1"))
        #expect(String(decoding: version, as: UTF8.self).contains("awesomux-handoff-v1"))
    }

    @Test(
        "installation rejects process failures and non-exact success output",
        arguments: [
            "cat >/dev/null; exit 7",
            "cat >/dev/null; printf '%s' 'AWESOMUX_HELPER_INSTALLED extra'",
            "cat >/dev/null; head -c 5000 /dev/zero",
        ]
    )
    func installationRejectsFailures(body: String) async throws {
        let directory = try TemporaryDirectory(prefix: "helper-installer-failure")
        let prepared = try await RemoteHelperInstaller.prepareBundledHelper(
            at: try helper(in: directory, payload: Data("helper".utf8))
        )
        let executable = try shellScript(in: directory, body: body)
        let remote = try #require(RemoteTarget(parsing: "me@example"))

        await #expect(throws: RemoteHelperInstaller.Failure.installationFailed) {
            try await RemoteHelperInstaller.install(
                helper: prepared,
                remote: remote,
                controlPath: "/tmp/control/%C",
                remoteHome: "/Users/me",
                executableURL: executable,
                timeout: realSpawnTimeout
            )
        }
    }

    private func helper(in directory: TemporaryDirectory, payload: Data) throws -> URL {
        let url = directory.url.appendingPathComponent(RemoteHelperInstaller.helperName)
        try payload.write(to: url)
        guard chmod(url.path, 0o700) == 0 else { throw CocoaError(.fileWriteUnknown) }
        return url
    }

    private func shellScript(in directory: TemporaryDirectory, body: String) throws -> URL {
        let url = directory.url.appendingPathComponent("fake-ssh-\(UUID()).sh")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        guard chmod(url.path, 0o700) == 0 else { throw CocoaError(.fileWriteUnknown) }
        return url
    }

    private func passthroughSSH(in directory: TemporaryDirectory) throws -> URL {
        try shellScript(
            in: directory,
            body: """
                for argument do
                  remote_command=$argument
                done
                exec /bin/sh -c "$remote_command"
                """
        )
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
