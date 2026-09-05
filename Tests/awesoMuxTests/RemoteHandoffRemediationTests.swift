import AppKit
import AwesoMuxCore
import AwesoMuxTestSupport
import CryptoKit
import Darwin
import Foundation
import Testing
@testable import awesoMux

extension RemoteHandoffTests {
    @Suite("Clipboard helper remediation")
    @MainActor
    struct RemoteHandoffRemediationTests {
        @Test(
            "Linux install and update use verified architecture and version matched artifacts, then require another paste",
            arguments: [RemoteHelperInstaller.LinuxArchitecture.aarch64, .x86_64],
            [RemoteHelperInstaller.Capability.missing, .incompatible]
        )
        func linuxRemediation(
            architecture: RemoteHelperInstaller.LinuxArchitecture,
            capability: RemoteHelperInstaller.Capability
        ) async throws {
            let fixture = try Fixture()
            fixture.architecture = architecture
            fixture.initialCapability = capability
            let outcome = try await fixture.run()
            #expect(outcome == .retryPaste)
            #expect(fixture.actions == [capability.approvalAction])
            #expect(fixture.events == ["probe", "platform", "consent", "acquire", "install", "verify", "success"])
            #expect(try Data(contentsOf: fixture.installedURL) == fixture.payload)
            #expect(!FileManager.default.fileExists(atPath: fixture.acquiredURL!.path))
        }

        @Test("GNU stat fallback discards failed output and still rejects unsafe directories", arguments: [false, true])
        func linuxStatValidation(unsafeLayout: Bool) async throws {
            let fixture = try Fixture(gnuStat: true)
            if unsafeLayout {
                #expect(chmod(fixture.home.appendingPathComponent(".awesomux").path, 0o755) == 0)
                await #expect(throws: RemoteHelperInstaller.Failure.unsafeRemoteLayout) {
                    try await fixture.run()
                }
                #expect(try Data(contentsOf: fixture.installedURL) == fixture.previous)
            } else {
                #expect(try await fixture.run() == .retryPaste)
                #expect(try Data(contentsOf: fixture.installedURL) == fixture.payload)
            }
        }

        @Test("Compatible helpers proceed without acquisition or installation")
        func compatibleHelper() async throws {
            let fixture = try Fixture()
            fixture.initialCapability = .supported
            #expect(try await fixture.run() == .readyToTransfer)
            #expect(fixture.events == ["probe"])
        }

        @Test("Probe failure does not offer installation")
        func probeFailure() async throws {
            let fixture = try Fixture()
            fixture.initialCapability = .probeFailed
            await #expect(throws: RemoteHelperInstaller.Failure.helperProbeFailed) {
                try await fixture.run()
            }
            #expect(fixture.events == ["probe"])
        }

        @Test("Declining consent leaves the prior helper without acquiring bytes")
        func declinedConsent() async throws {
            let fixture = try Fixture()
            fixture.approve = false
            #expect(try await fixture.run() == .cancelled)
            #expect(!fixture.events.contains("install"))
            #expect(try Data(contentsOf: fixture.installedURL) == fixture.previous)
            #expect(fixture.acquiredURL == nil)
            #expect(!fixture.events.contains("acquire"))
        }

        @Test(
            "Stale pane or host stops after each suspension",
            arguments: ["initial", "probe", "platform", "consent", "acquire", "install", "verify"],
            ["pane", "host"])
        func staleAuthority(stage: String, replacement: String) async throws {
            let fixture = try Fixture()
            defer { fixture.afterStage = { _ in } }
            fixture.afterStage = { currentStage in
                guard currentStage == stage else { return }
                if replacement == "pane" {
                    fixture.pane.terminalSessionID = .generate()
                } else {
                    fixture.pane.executionPlan = .ssh(
                        SSHExecution(target: try #require(RemoteTarget(parsing: "other@example")))
                    )
                }
            }
            await #expect(throws: RemoteHandoff.Failure.destinationChanged) {
                try await fixture.run()
            }
            assertStopped(fixture, after: stage)
        }

        @Test(
            "Cancellation stops after each suspension",
            arguments: ["initial", "probe", "platform", "consent", "acquire", "install", "verify"])
        func cancellation(stage: String) async throws {
            let fixture = try Fixture()
            defer { fixture.afterStage = { _ in } }
            fixture.afterStage = { currentStage in
                if currentStage == stage {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
            let task = Task { try await fixture.run() }
            await #expect(throws: CancellationError.self) { try await task.value }
            assertStopped(fixture, after: stage)
        }

        @Test(
            "Unavailable and corrupt release artifacts never reach installation",
            arguments: [RemoteHelperInstaller.Failure.releaseArtifactUnavailable, .releaseArtifactChecksumMismatch])
        func acquisitionFailure(failure: RemoteHelperInstaller.Failure) async throws {
            let fixture = try Fixture()
            fixture.acquisitionFailure = failure
            await #expect(throws: failure) { try await fixture.run() }
            #expect(fixture.events.contains("consent"))
            #expect(!fixture.events.contains("install"))
            #expect(try Data(contentsOf: fixture.installedURL) == fixture.previous)
            if failure == .releaseArtifactChecksumMismatch {
                #expect(!FileManager.default.fileExists(atPath: fixture.downloadURL.path))
            }
        }

        @Test("Checksum request failure cleans a successful concurrent binary download")
        func checksumRequestFailure() async throws {
            let fixture = try Fixture()
            fixture.checksumRequestFails = true
            await #expect(throws: RemoteHelperInstaller.Failure.releaseArtifactUnavailable) {
                try await fixture.run()
            }
            #expect(!FileManager.default.fileExists(atPath: fixture.downloadURL.path))
            #expect(try Data(contentsOf: fixture.installedURL) == fixture.previous)
            #expect(fixture.events == ["probe", "platform", "consent", "acquire"])
        }

        @Test("Checksum request failure cancels an in-flight binary download")
        func checksumFailureCancelsBinary() async throws {
            let fixture = try Fixture()
            fixture.checksumRequestFails = true
            fixture.suspendBinaryDownload = true
            await #expect(throws: RemoteHelperInstaller.Failure.releaseArtifactUnavailable) {
                try await fixture.run()
            }
            #expect(await fixture.downloadCancellation.wasCancelled)
            #expect(try Data(contentsOf: fixture.installedURL) == fixture.previous)
            #expect(!fixture.events.contains("install"))
        }

        @Test("Failed staged replacement preserves the old helper and removes temporary files")
        func failedReplacement() async throws {
            let fixture = try Fixture()
            fixture.payload = Data("#!/bin/sh\nprintf '%s\\n' awesomux-bridge-v1\n".utf8)
            await #expect(throws: RemoteHelperInstaller.Failure.installationFailed) {
                try await fixture.run()
            }
            #expect(try Data(contentsOf: fixture.installedURL) == fixture.previous)
            #expect(
                try FileManager.default.contentsOfDirectory(atPath: fixture.installedURL.deletingLastPathComponent().path)
                    == ["awesomux-bridge-helper"])
            #expect(!FileManager.default.fileExists(atPath: fixture.acquiredURL!.path))
            #expect(!fixture.events.contains("verify"))
            #expect(!fixture.events.contains("success"))
        }

        @Test(
            "Post-install verification must succeed before reporting success",
            arguments: [RemoteHelperInstaller.Capability.missing, .incompatible, .probeFailed])
        func verificationFailure(capability: RemoteHelperInstaller.Capability) async throws {
            let fixture = try Fixture()
            fixture.verifiedCapability = capability
            let expected: RemoteHelperInstaller.Failure =
                capability == .probeFailed ? .verificationFailed : .installedHelperIncompatible
            await #expect(throws: expected) { try await fixture.run() }
            #expect(fixture.events.contains("verify"))
            #expect(!fixture.events.contains("success"))
            #expect(!FileManager.default.fileExists(atPath: fixture.acquiredURL!.path))
        }

        private func assertStopped(_ fixture: Fixture, after stage: String) {
            let sequence = ["probe", "platform", "consent", "acquire", "install", "verify", "success"]
            let expected = stage == "initial" ? [] : Array(sequence.prefix(through: sequence.firstIndex(of: stage)!))
            #expect(fixture.events == expected)
            if let acquiredURL = fixture.acquiredURL {
                #expect(!FileManager.default.fileExists(atPath: acquiredURL.path))
            }
        }

        private actor DownloadCancellation {
            var wasCancelled = false
            func record() { wasCancelled = true }
        }

        @MainActor
        private final class Fixture {
            let directory: TemporaryDirectory
            let remote: RemoteTarget
            var pane: TerminalPane
            let authority: RemoteHandoff.Authority
            let home: URL
            let installedURL: URL
            let downloadURL: URL
            let transport: URL
            let previous = Data("previous helper".utf8)
            var payload = Data("#!/bin/sh\nprintf '%s\\n' awesomux-bridge-v1 awesomux-handoff-v1\n".utf8)
            var initialCapability: RemoteHelperInstaller.Capability = .incompatible
            var verifiedCapability: RemoteHelperInstaller.Capability = .supported
            var architecture: RemoteHelperInstaller.LinuxArchitecture = .aarch64
            var approve = true
            var acquisitionFailure: RemoteHelperInstaller.Failure?
            var checksumRequestFails = false
            var suspendBinaryDownload = false
            let downloadCancellation = DownloadCancellation()
            var acquiredURL: URL?
            var events: [String] = []
            var actions: [RemoteHelperInstaller.ApprovalAction?] = []
            var afterStage: (String) throws -> Void = { _ in }

            init(gnuStat: Bool = false) throws {
                directory = try TemporaryDirectory(prefix: "handoff-remediation")
                remote = try #require(RemoteTarget(parsing: "me@example"))
                pane = TerminalPane(
                    terminalSessionID: .generate(), title: "remote", workingDirectory: "~",
                    executionPlan: .ssh(SSHExecution(target: remote))
                )
                authority = RemoteHandoff.Authority(
                    appSessionID: UUID(), paneID: pane.id, terminalSessionID: pane.terminalSessionID,
                    executionPlan: pane.executionPlan, remote: remote
                )
                home = directory.url.appendingPathComponent("remote-home")
                installedURL = home.appendingPathComponent(".awesomux/bin/awesomux-bridge-helper")
                downloadURL = directory.url.appendingPathComponent("download")
                transport = directory.url.appendingPathComponent("fake-ssh")
                try FileManager.default.createDirectory(
                    at: installedURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                try previous.write(to: installedURL)
                var statRewrite = ""
                if gnuStat {
                    let statURL = directory.url.appendingPathComponent("gnu-stat")
                    try Data(
                        """
                        #!/bin/sh
                        if [ "$1" = "-f" ]; then
                            printf '%s\\n' 'File: filesystem information from a failed GNU stat call'
                            exit 1
                        fi
                        case "$2" in
                            %u) format=%u ;;
                            %a) format=%Lp ;;
                            %s) format=%z ;;
                            *) exit 1 ;;
                        esac
                        exec /usr/bin/stat -f "$format" "$3"
                        """.utf8
                    ).write(to: statURL)
                    #expect(chmod(statURL.path, 0o700) == 0)
                    statRewrite = "remote_command=$(printf '%s' \"$remote_command\" | /usr/bin/sed 's|/usr/bin/stat|\(statURL.path)|g')"
                }
                try Data(
                    """
                    #!/bin/sh
                    for argument do
                      remote_command=$argument
                    done
                    \(statRewrite)
                    exec /bin/sh -c "$remote_command"
                    """.utf8
                ).write(to: transport)
                #expect(chmod(transport.path, 0o700) == 0)
                #expect(chmod(installedURL.path, 0o700) == 0)
            }

            func run() async throws -> RemoteHelperInstaller.HandoffHelperOutcome {
                try afterStage("initial")
                return try await RemoteHelperInstaller.prepareHandoffHelper(
                    remote: remote, controlPath: "/tmp/fake-control/%C", remoteHome: home.path,
                    helperPath: installedURL.path, window: nil,
                    authorityIsCurrent: { RemoteHandoff.authorityMatches(self.authority, pane: self.pane) },
                    version: "1.2.3",
                    capabilityProbe: { remote, control, path in
                        #expect(remote == self.remote)
                        #expect(control == "/tmp/fake-control/%C")
                        #expect(path == self.installedURL.path)
                        let isVerification = self.events.contains("install")
                        let stage = isVerification ? "verify" : "probe"
                        self.events.append(stage)
                        try self.afterStage(stage)
                        return isVerification ? self.verifiedCapability : self.initialCapability
                    },
                    platformProbe: { remote, _ in
                        #expect(remote == self.remote)
                        self.events.append("platform")
                        try self.afterStage("platform")
                        return .linux(self.architecture)
                    },
                    acquisition: { platform, version in
                        self.events.append("acquire")
                        #expect(platform == .linux(self.architecture))
                        #expect(version == "1.2.3")
                        let artifact = try #require(
                            RemoteHelperInstaller.releaseArtifact(
                                version: version, architecture: self.architecture
                            ))
                        let digest = SHA256.hash(data: self.payload).map { String(format: "%02x", $0) }.joined()
                        let checksum =
                            self.acquisitionFailure == .releaseArtifactChecksumMismatch
                            ? String(repeating: "0", count: 64) : digest
                        let checksumData = Data("\(checksum)  \(artifact.filename)\n".utf8)
                        let downloadURL = self.downloadURL
                        let unavailable = self.acquisitionFailure == .releaseArtifactUnavailable
                        let checksumRequestFails = self.checksumRequestFails
                        let suspendBinaryDownload = self.suspendBinaryDownload
                        let downloadCancellation = self.downloadCancellation
                        try self.payload.write(to: downloadURL)
                        let acquired = try await RemoteHelperInstaller.acquireHelper(
                            for: platform,
                            version: version,
                            dataDownload: { url in
                                #expect(url == artifact.checksumURL)
                                if checksumRequestFails { throw URLError(.cannotConnectToHost) }
                                return checksumData
                            },
                            fileDownload: { url in
                                #expect(url == artifact.binaryURL)
                                if unavailable { throw URLError(.fileDoesNotExist) }
                                if suspendBinaryDownload {
                                    do {
                                        try await Task.sleep(for: .seconds(30))
                                    } catch {
                                        await downloadCancellation.record()
                                        throw error
                                    }
                                    Issue.record("The binary download was not cancelled")
                                }
                                return downloadURL
                            }
                        )
                        self.acquiredURL = acquired.prepared.url
                        try self.afterStage("acquire")
                        return acquired
                    },
                    confirmation: { action, remote, _ in
                        #expect(remote == self.remote)
                        self.actions.append(action)
                        self.events.append("consent")
                        try? self.afterStage("consent")
                        return self.approve
                    },
                    installOperation: { helper, remote, control, home in
                        self.events.append("install")
                        try await RemoteHelperInstaller.install(
                            helper: helper, remote: remote, controlPath: control, remoteHome: home,
                            executableURL: self.transport, timeout: realSpawnTimeout
                        )
                        try self.afterStage("install")
                    },
                    successPresentation: { _ in self.events.append("success") }
                )
            }
        }
    }

}
