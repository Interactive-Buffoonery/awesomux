import AwesoMuxCore
import AwesoMuxTestSupport
import Darwin
import Foundation
import Testing
@testable import awesoMux

@Suite("Remote helper installer", .serialized)
struct RemoteHelperInstallerTests {
    @Test("bundled helper resolves beside the app executable")
    func bundledHelperResolution() {
        let executable = URL(fileURLWithPath: "/Applications/awesoMux.app/Contents/MacOS/awesoMux")
        #expect(
            RemoteHelperInstaller.bundledHelperURL(executableURL: executable)?.path
                == "/Applications/awesoMux.app/Contents/MacOS/awesoMuxBridgeHelper"
        )
    }

    @Test("bundled helper preparation snapshots executable bytes and digest")
    func helperPreparation() throws {
        let directory = try TemporaryDirectory(prefix: "helper-installer-source")
        let payload = Data("helper bytes".utf8)
        let helperURL = try helper(in: directory, payload: payload)

        let prepared = try RemoteHelperInstaller.prepareBundledHelper(at: helperURL)

        #expect(prepared.byteCount == payload.count)
        #expect(prepared.sha256.count == 64)
        #expect(
            prepared.sha256.unicodeScalars.allSatisfy {
                (0x30...0x39).contains($0.value) || (0x61...0x66).contains($0.value)
            })
        let descriptor = try prepared.openValidated()
        close(descriptor)
    }

    @Test("bundled helper preparation rejects unsafe source types")
    func helperPreparationRejectsUnsafeSources() throws {
        let directory = try TemporaryDirectory(prefix: "helper-installer-source-reject")
        let directoryURL = directory.url.appendingPathComponent("directory")
        let plainFile = directory.url.appendingPathComponent("plain")
        let symlink = directory.url.appendingPathComponent("symlink")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: false)
        try Data("x".utf8).write(to: plainFile)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: plainFile)

        for url in [directoryURL, plainFile, symlink] {
            #expect(throws: RemoteHelperInstaller.Failure.bundledHelperUnavailable) {
                try RemoteHelperInstaller.prepareBundledHelper(at: url)
            }
        }
    }

    @Test("source replacement after preparation is rejected")
    func helperReplacementIsRejected() throws {
        let directory = try TemporaryDirectory(prefix: "helper-installer-replacement")
        let helperURL = try helper(in: directory, payload: Data("original".utf8))
        let prepared = try RemoteHelperInstaller.prepareBundledHelper(at: helperURL)
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

    @Test(
        "platform gate accepts only supported Apple Silicon macOS",
        arguments: [
            ("Darwin\n15.0\narm64\n", true),
            ("Darwin\n26.4.1\narm64\n", true),
            ("Darwin\n14.7\narm64\n", false),
            ("Darwin\n26.0\nx86_64\n", false),
            ("Linux\n6.8\nx86_64\n", false),
            ("Darwin\n26.0\narm64\nextra\n", false),
            ("malformed", false),
        ]
    )
    func platformGate(output: String, accepted: Bool) {
        #expect((RemoteHelperInstaller.supportedPlatform(from: Data(output.utf8)) != nil) == accepted)
    }

    @Test("SSH arguments preserve declared authority and transport posture")
    func sshArguments() throws {
        let remote = try #require(RemoteTarget(parsing: "me@example"))
        let arguments = RemoteHelperInstaller.sshArguments(
            remote: remote,
            controlPath: "/tmp/control/%C",
            remoteCommand: "fixed command"
        )

        #expect(arguments.contains("ControlMaster=auto"))
        #expect(arguments.contains("ControlPath=/tmp/control/%C"))
        #expect(arguments.contains("ConnectTimeout=10"))
        #expect(arguments.suffix(3) == ["--", "me@example", "fixed command"])
    }

    @Test("bootstrap command stages, validates, and atomically replaces the helper")
    func bootstrapCommand() {
        let digest = String(repeating: "a", count: 64)
        let command = RemoteHelperInstaller.bootstrapScript(
            remoteHome: "/Users/remote user",
            expectedBytes: 123,
            sha256: digest
        )

        #expect(command.contains("/Users/remote user/.awesomux/bin/awesomux-bridge-helper"))
        #expect(command.contains("mktemp"))
        #expect(command.contains("stat -f '%z'"))
        #expect(command.contains("= 123"))
        #expect(command.contains(digest))
        #expect(command.contains("awesomux-bridge-v1"))
        #expect(command.contains("awesomux-handoff-v1"))
        #expect(command.contains("/bin/mv -f"))
        #expect(command.contains("trap '/bin/rm -f"))
        #expect(!command.contains("sudo"))
        #expect(!command.contains("curl"))
        #expect(!command.contains("scp"))
        #expect(!command.contains("/Users/local/private"))
    }

    @Test("installation streams only verified helper bytes and accepts the fixed success token")
    func installationStreamsHelper() async throws {
        let directory = try TemporaryDirectory(prefix: "helper-installer-transfer")
        let payload = Data("signed helper bytes".utf8)
        let helperURL = try helper(in: directory, payload: payload)
        let prepared = try RemoteHelperInstaller.prepareBundledHelper(at: helperURL)
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
        #expect(arguments.contains(prepared.sha256))
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
        let prepared = try RemoteHelperInstaller.prepareBundledHelper(
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
            timeout: .seconds(2)
        )
        #expect(String(decoding: version, as: UTF8.self).contains("awesomux-bridge-v1"))
        #expect(String(decoding: version, as: UTF8.self).contains("awesomux-handoff-v1"))
    }

    @Test("failed staged validation preserves an existing helper and removes the temporary")
    func bootstrapFailurePreservesExistingHelper() async throws {
        let directory = try TemporaryDirectory(prefix: "helper-installer-bootstrap-failure")
        let incompatiblePayload = Data(
            """
            #!/bin/sh
            printf '%s\\n' awesomux-bridge-v1
            """.utf8
        )
        let prepared = try RemoteHelperInstaller.prepareBundledHelper(
            at: try helper(in: directory, payload: incompatiblePayload)
        )
        let remoteHome = directory.url.appendingPathComponent("remote-home")
        let binDirectory = remoteHome.appendingPathComponent(".awesomux/bin")
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        guard chmod(remoteHome.appendingPathComponent(".awesomux").path, 0o700) == 0,
            chmod(binDirectory.path, 0o700) == 0
        else {
            throw CocoaError(.fileWriteUnknown)
        }
        let installed = binDirectory.appendingPathComponent("awesomux-bridge-helper")
        let previous = Data("previous helper".utf8)
        try previous.write(to: installed)
        guard chmod(installed.path, 0o700) == 0 else { throw CocoaError(.fileWriteUnknown) }
        let executable = try passthroughSSH(in: directory)
        let remote = try #require(RemoteTarget(parsing: "me@example"))

        await #expect(throws: RemoteHelperInstaller.Failure.installationFailed) {
            try await RemoteHelperInstaller.install(
                helper: prepared,
                remote: remote,
                controlPath: "/tmp/control/%C",
                remoteHome: remoteHome.path,
                executableURL: executable,
                timeout: .seconds(10)
            )
        }

        #expect(try Data(contentsOf: installed) == previous)
        let names = try FileManager.default.contentsOfDirectory(atPath: binDirectory.path)
        #expect(names == ["awesomux-bridge-helper"])
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
        let prepared = try RemoteHelperInstaller.prepareBundledHelper(
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
                timeout: .seconds(2)
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
