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

    @Test(arguments: [
        (
            "missing", 10,
            [
                "missing environment", "AWESOMUX_AGENT_EVENT_PROTOCOL", "AWESOMUX_SESSION_ID", "AWESOMUX_PANE_ID",
                "AWESOMUX_AGENT_EVENT_FILE",
            ]
        ),
        ("protocol", 20, ["bad protocol", AgentRuntimeEvent.protocolName]),
        ("session", 30, ["invalid UUID", "AWESOMUX_SESSION_ID"]),
        ("pane", 31, ["invalid UUID", "AWESOMUX_PANE_ID"]),
        ("stale", 40, ["stale pane/file mismatch"]),
        ("absent", 50, ["missing event file"]),
        ("directory", 51, ["non-regular event file"]),
        ("owner", 52, ["wrong owner", "owner=502", "expected=501"]),
        ("writable", 53, ["non-writable event file"]),
        ("hook", 0, [String]()),
    ])
    func diagnosticFailure(kind: String, code: Int32, fragments: [String]) throws {
        let paneID = UUID()
        let filePaneID = kind == "stale" ? UUID() : paneID
        let temp =
            try kind == "directory"
            ? Self.temporaryEventDirectory(paneID: paneID)
            : Self.temporaryEventFile(paneID: filePaneID, createFile: kind != "absent")
        defer { temp.remove() }
        var environment = Self.environment(paneID: paneID, eventFile: temp.file)
        switch kind {
        case "missing", "hook": environment = [:]
        case "protocol": environment["AWESOMUX_AGENT_EVENT_PROTOCOL"] = "awesomux-agent-v0"
        case "session": environment["AWESOMUX_SESSION_ID"] = "not-a-uuid"
        case "pane": environment["AWESOMUX_PANE_ID"] = "not-a-uuid"
        default: break
        }
        if kind == "hook" || kind == "missing" {
            var stdout: [String] = []
            var stderr: [String] = []
            let arguments = kind == "hook" ? ["--provider", "codex"] : ["--health-check"]
            let status = AgentHookCommand.run(
                arguments: arguments, environment: environment,
                stdin: Data(#"{"hook_event_name":"SessionStart"}"#.utf8),
                output: { stdout.append($0) }, errorOutput: { stderr.append($0) }
            )
            #expect(status == code)
            #expect(stdout.isEmpty)
            #expect(AgentHookCommand.shouldReadStandardInput(arguments: arguments) == (kind == "hook"))
            if kind == "hook" { #expect(stderr.isEmpty); return }
            #expect(stderr.count == 1)
            #expect(stderr.first?.contains("health check failed") == true)
        }
        let result: AgentHookHealthCheck.Result
        if kind == "owner" || kind == "writable" {
            result = AgentHookHealthCheck.diagnose(
                environment: environment,
                effectiveUID: kind == "owner" ? 501 : Darwin.geteuid(),
                fileInfoProvider: { _ in
                    .init(
                        exists: true, isRegularFile: true,
                        ownerUID: kind == "owner" ? 502 : Darwin.geteuid(),
                        canOpenForAppend: kind != "writable"
                    )
                }
            )
        } else {
            result = AgentHookHealthCheck.diagnose(environment: environment)
        }
        #expect(result.exitCode == code)
        for fragment in fragments { #expect(result.message.contains(fragment)) }
        if kind == "stale" {
            #expect(result.message.contains(paneID.uuidString))
            #expect(result.message.contains(filePaneID.uuidString))
        }
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
