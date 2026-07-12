import AwesoMuxCore
import Darwin
import Foundation
import Testing
@testable import AwesoMuxAgentHookSupport

@Suite
struct AgentHookHealthCheckTests {
    @Test
    func healthCheckSkipsStdinAndReportsSuccess() throws {
        let paneID = UUID()
        let temp = try Self.temporaryEventFile(paneID: paneID)
        defer { temp.remove() }
        var stdout: [String] = []
        var stderr: [String] = []

        let status = AgentHookCommand.run(
            arguments: ["--health-check"],
            environment: Self.environment(paneID: paneID, eventFile: temp.file),
            stdin: Data("ignored".utf8),
            output: { stdout.append($0) },
            errorOutput: { stderr.append($0) }
        )

        #expect(status == 0)
        #expect(stdout.count == 1)
        #expect(stdout[0].contains("health check OK"))
        #expect(stdout[0].contains("does not confirm the app consumed an event"))
        #expect(stderr.isEmpty)
        #expect(AgentHookCommand.shouldReadStandardInput(arguments: ["--health-check"]) == false)
    }

    @Test
    func hookModeStillSilentlyIgnoresMissingEnvironment() {
        var stdout: [String] = []
        var stderr: [String] = []

        let status = AgentHookCommand.run(
            arguments: ["--provider", "codex"],
            environment: [:],
            stdin: Data(#"{"hook_event_name":"SessionStart"}"#.utf8),
            output: { stdout.append($0) },
            errorOutput: { stderr.append($0) }
        )

        #expect(status == 0)
        #expect(stdout.isEmpty)
        #expect(stderr.isEmpty)
        #expect(AgentHookCommand.shouldReadStandardInput(arguments: ["--provider", "codex"]))
    }

    @Test
    func missingEnvironmentReportsDiagnostics() {
        let result = AgentHookHealthCheck.diagnose(environment: [:])

        #expect(result.exitCode == 10)
        #expect(result.message.contains("missing environment"))
        #expect(result.message.contains("AWESOMUX_AGENT_EVENT_PROTOCOL"))
        #expect(result.message.contains("AWESOMUX_SESSION_ID"))
        #expect(result.message.contains("AWESOMUX_PANE_ID"))
        #expect(result.message.contains("AWESOMUX_AGENT_EVENT_FILE"))
    }

    @Test
    func badProtocolReportsDiagnostics() throws {
        let paneID = UUID()
        let temp = try Self.temporaryEventFile(paneID: paneID)
        defer { temp.remove() }
        var environment = Self.environment(paneID: paneID, eventFile: temp.file)
        environment["AWESOMUX_AGENT_EVENT_PROTOCOL"] = "awesomux-agent-v0"

        let result = AgentHookHealthCheck.diagnose(environment: environment)

        #expect(result.exitCode == 20)
        #expect(result.message.contains("bad protocol"))
        #expect(result.message.contains(AgentRuntimeEvent.protocolName))
    }

    @Test
    func invalidUUIDReportsDiagnostics() throws {
        let paneID = UUID()
        let temp = try Self.temporaryEventFile(paneID: paneID)
        defer { temp.remove() }
        var environment = Self.environment(paneID: paneID, eventFile: temp.file)
        environment["AWESOMUX_SESSION_ID"] = "not-a-uuid"

        let result = AgentHookHealthCheck.diagnose(environment: environment)

        #expect(result.exitCode == 30)
        #expect(result.message.contains("invalid UUID"))
        #expect(result.message.contains("AWESOMUX_SESSION_ID"))
    }

    @Test
    func invalidPaneIDReportsDiagnostics() throws {
        let paneID = UUID()
        let temp = try Self.temporaryEventFile(paneID: paneID)
        defer { temp.remove() }
        var environment = Self.environment(paneID: paneID, eventFile: temp.file)
        environment["AWESOMUX_PANE_ID"] = "not-a-uuid"

        let result = AgentHookHealthCheck.diagnose(environment: environment)

        #expect(result.exitCode == 31)
        #expect(result.message.contains("invalid UUID"))
        #expect(result.message.contains("AWESOMUX_PANE_ID"))
    }

    @Test
    func stalePaneFileMismatchReportsDiagnostics() throws {
        let paneID = UUID()
        let otherPaneID = UUID()
        let temp = try Self.temporaryEventFile(paneID: otherPaneID)
        defer { temp.remove() }

        let result = AgentHookHealthCheck.diagnose(
            environment: Self.environment(paneID: paneID, eventFile: temp.file)
        )

        #expect(result.exitCode == 40)
        #expect(result.message.contains("stale pane/file mismatch"))
        #expect(result.message.contains(paneID.uuidString))
        #expect(result.message.contains(otherPaneID.uuidString))
    }

    @Test
    func missingEventFileReportsDiagnostics() throws {
        let paneID = UUID()
        let temp = try Self.temporaryEventFile(paneID: paneID, createFile: false)
        defer { temp.remove() }

        let result = AgentHookHealthCheck.diagnose(
            environment: Self.environment(paneID: paneID, eventFile: temp.file)
        )

        #expect(result.exitCode == 50)
        #expect(result.message.contains("missing event file"))
    }

    @Test
    func nonRegularPathReportsDiagnostics() throws {
        let paneID = UUID()
        let temp = try Self.temporaryEventDirectory(paneID: paneID)
        defer { temp.remove() }

        let result = AgentHookHealthCheck.diagnose(
            environment: Self.environment(paneID: paneID, eventFile: temp.file)
        )

        #expect(result.exitCode == 51)
        #expect(result.message.contains("non-regular event file"))
    }

    @Test
    func wrongOwnerReportsDiagnostics() throws {
        let paneID = UUID()
        let temp = try Self.temporaryEventFile(paneID: paneID)
        defer { temp.remove() }
        let expectedUID = uid_t(501)
        let ownerUID = uid_t(502)

        let result = AgentHookHealthCheck.diagnose(
            environment: Self.environment(paneID: paneID, eventFile: temp.file),
            effectiveUID: expectedUID,
            fileInfoProvider: { _ in
                AgentHookHealthCheck.FileInfo(
                    exists: true,
                    isRegularFile: true,
                    ownerUID: ownerUID,
                    canOpenForAppend: true
                )
            }
        )

        #expect(result.exitCode == 52)
        #expect(result.message.contains("wrong owner"))
        #expect(result.message.contains("owner=\(ownerUID)"))
        #expect(result.message.contains("expected=\(expectedUID)"))
    }

    @Test
    func nonWritablePathReportsDiagnostics() throws {
        let paneID = UUID()
        let temp = try Self.temporaryEventFile(paneID: paneID)
        defer { temp.remove() }

        let result = AgentHookHealthCheck.diagnose(
            environment: Self.environment(paneID: paneID, eventFile: temp.file),
            fileInfoProvider: { _ in
                AgentHookHealthCheck.FileInfo(
                    exists: true,
                    isRegularFile: true,
                    ownerUID: Darwin.geteuid(),
                    canOpenForAppend: false
                )
            }
        )

        #expect(result.exitCode == 53)
        #expect(result.message.contains("non-writable event file"))
    }

    @Test
    func healthCheckFailureWritesToStderr() {
        var stdout: [String] = []
        var stderr: [String] = []

        let status = AgentHookCommand.run(
            arguments: ["--health-check"],
            environment: [:],
            stdin: Data(),
            output: { stdout.append($0) },
            errorOutput: { stderr.append($0) }
        )

        #expect(status == 10)
        #expect(stdout.isEmpty)
        #expect(stderr.count == 1)
        #expect(stderr[0].contains("health check failed"))
    }

    private static func environment(
        paneID: UUID,
        eventFile: URL,
        sessionID: UUID = UUID()
    ) -> [String: String] {
        [
            "AWESOMUX_AGENT_EVENT_PROTOCOL": AgentRuntimeEvent.protocolName,
            "AWESOMUX_SESSION_ID": sessionID.uuidString,
            "AWESOMUX_PANE_ID": paneID.uuidString,
            "AWESOMUX_AGENT_EVENT_FILE": eventFile.path
        ]
    }

    private static func temporaryEventFile(
        paneID: UUID,
        createFile: Bool = true
    ) throws -> TemporaryEventPath {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "awesomux-agent-health-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "\(paneID.uuidString).jsonl")
        if createFile {
            _ = FileManager.default.createFile(atPath: file.path, contents: nil)
        }
        return TemporaryEventPath(directory: directory, file: file)
    }

    private static func temporaryEventDirectory(paneID: UUID) throws -> TemporaryEventPath {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "awesomux-agent-health-\(UUID().uuidString)", directoryHint: .isDirectory)
        let file = directory.appending(path: "\(paneID.uuidString).jsonl", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        return TemporaryEventPath(directory: directory, file: file)
    }
}

private struct TemporaryEventPath {
    let directory: URL
    let file: URL

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
