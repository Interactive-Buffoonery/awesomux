import AwesoMuxBridgeProtocol
import Foundation
import Darwin
import Testing
@testable import AwesoMuxAgentHookSupport
@testable import AwesoMuxCore

@Suite
struct AgentHookCommandTests {

    @Test("nested Codex lifecycle hooks write nothing")
    func nestedCodexLifecycleHooksWriteNothing() throws {
        let hookNames = [
            "SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest",
            "PostToolUse", "SubagentStart", "SubagentStop", "Stop", "SessionEnd",
            "StopFailure", "Notification",
        ]

        for hookName in hookNames {
            let temp = try Self.temporaryEventFile()
            defer { temp.remove() }
            let status = AgentHookCommand.run(
                arguments: ["--provider", "codex"],
                environment: [
                    "AWESOMUX_AGENT_EVENT_FILE": temp.file.path,
                    "CLAUDE_CODE_CHILD_SESSION": "1",
                ],
                stdin: Self.hookPayload(hookName)
            )

            #expect(status == 0)
            #expect(try Data(contentsOf: temp.file).isEmpty)
        }
    }

    @Test("nested ingress cannot claim a fresh pane before an explicit document and direct Codex lifecycle")
    @MainActor
    func nestedIngressPreservesFreshPaneIdentityUntilDirectCodexLifecycle() throws {
        let temp = try Self.temporaryEventFile()
        defer { temp.remove() }
        let environment = [
            "AWESOMUX_AGENT_EVENT_FILE": temp.file.path,
            "CLAUDE_CODE_CHILD_SESSION": "1",
        ]
        let session = TerminalSession(title: "shell", workingDirectory: "~", agentKind: .shell)
        let store = SessionStore(groups: [SessionGroup(name: "main", sessions: [session])])

        #expect(
            AgentHookCommand.run(
                arguments: ["--provider", "codex"],
                environment: environment,
                stdin: Self.hookPayload("SessionStart", providerSessionID: "3f2b1c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d")
            ) == 0)
        #expect(try Data(contentsOf: temp.file).isEmpty)
        #expect(store.agentProviderSessionID(for: session.activePaneID) == nil)
        #expect(store.lastEndedAgentTranscriptIdentity(for: session.activePaneID) == nil)

        #expect(
            AgentHookCommand.run(
                arguments: ["open-document", "--provider", "codex", "/tmp/notes.md"],
                environment: environment,
                stdin: Data()
            ) == 0)
        let documentEvent = try #require(try Self.readSingleEvent(from: temp.file))
        _ = store.applyAgentRuntimeEvent(documentEvent, to: session.id, paneID: session.activePaneID)
        #expect(store.session(id: session.id)?.agentKind == .shell)
        #expect(store.agentProviderSessionID(for: session.activePaneID) == nil)
        #expect(store.lastEndedAgentTranscriptIdentity(for: session.activePaneID) == nil)

        let directEnvironment = ["AWESOMUX_AGENT_EVENT_FILE": temp.file.path]
        let codexSessionID = "9a8b7c6d-5e4f-4321-9876-543210fedcba"
        #expect(
            AgentHookCommand.run(
                arguments: ["--provider", "codex"],
                environment: directEnvironment,
                stdin: Self.hookPayload("SessionStart", providerSessionID: codexSessionID)
            ) == 0)
        let startEvent = try #require(try Self.readEvents(from: temp.file).last)
        #expect(store.applyAgentRuntimeEvent(startEvent, to: session.id, paneID: session.activePaneID))
        #expect(store.agentProviderSessionID(for: session.activePaneID) == codexSessionID)

        #expect(
            AgentHookCommand.run(
                arguments: ["--provider", "codex"],
                environment: directEnvironment,
                stdin: Self.hookPayload("SessionEnd", providerSessionID: codexSessionID)
            ) == 0)
        let endEvent = try #require(try Self.readEvents(from: temp.file).last)
        #expect(store.applyAgentRuntimeEvent(endEvent, to: session.id, paneID: session.activePaneID))
        #expect(
            store.lastEndedAgentTranscriptIdentity(for: session.activePaneID)
                == AgentTranscriptIdentity(agentKind: .codex, sessionID: codexSessionID)
        )
    }

    // MARK: - Touched-path forwarding (issue #175)

    @Test(arguments: [
        "/Users/agent/main.swift",  // non-Markdown extension
        "relative/notes.md",  // not absolute
        "/Users/agent/re\u{202e}port.md",  // bidi-override scalar
        "/Users/agent/#175.md",  // `#` strips as a link fragment → un-openable
    ])
    func ineligibleTouchedPathIsDroppedButEventSurvives(filePath: String) throws {
        let temp = try Self.temporaryEventFile()
        defer { temp.remove() }

        let status = AgentHookCommand.run(
            arguments: ["--provider", "claude-code"],
            environment: ["AWESOMUX_AGENT_EVENT_FILE": temp.file.path],
            stdin: Self.postToolUsePayload(toolName: "Write", filePath: filePath)
        )

        #expect(status == 0)
        let event = try #require(try Self.readSingleEvent(from: temp.file))
        // The state transition still lands; only the path is dropped.
        #expect(event.phase == .toolEnd)
        #expect(event.executionState == .thinking)
        #expect(event.touchedPath == nil)
    }

    @Test(arguments: [
        #"{"hook_event_name":"PostToolUse","tool_name":123,"tool_input":{"file_path":"/Users/agent/plan.md"}}"#,
        #"{"hook_event_name":"PostToolUse","tool_name":["Write"],"tool_input":{"file_path":"/Users/agent/plan.md"}}"#,
        #"{"hook_event_name":"PostToolUse","tool_name":{"x":1},"tool_input":{"file_path":"/Users/agent/plan.md"}}"#,
    ])
    func malformedToolNameDoesNotSinkTheEvent(payload: String) throws {
        // A present-but-wrong-type tool_name must not throw out of the payload
        // decode and drop the event's lifecycle transition — it only gates
        // touched-path forwarding.
        let temp = try Self.temporaryEventFile()
        defer { temp.remove() }

        let status = AgentHookCommand.run(
            arguments: ["--provider", "claude-code"],
            environment: ["AWESOMUX_AGENT_EVENT_FILE": temp.file.path],
            stdin: Data(payload.utf8)
        )

        #expect(status == 0)
        let event = try #require(try Self.readSingleEvent(from: temp.file))
        #expect(event.phase == .toolEnd)
        #expect(event.executionState == .thinking)
        #expect(event.touchedPath == nil)
    }

    @Test
    func oversizedTouchedPathDegradesToLifecycleEventOnly() throws {
        // A path long enough to push the JSONL line past the 4 KiB cap must drop
        // only the path, not the whole toolEnd event and its transition.
        let temp = try Self.temporaryEventFile()
        defer { temp.remove() }

        let longName = String(repeating: "a", count: 4096)
        let status = AgentHookCommand.run(
            arguments: ["--provider", "claude-code"],
            environment: ["AWESOMUX_AGENT_EVENT_FILE": temp.file.path],
            stdin: Self.postToolUsePayload(toolName: "Write", filePath: "/\(longName).md")
        )

        #expect(status == 0)
        let event = try #require(try Self.readSingleEvent(from: temp.file))
        #expect(event.phase == .toolEnd)
        #expect(event.executionState == .thinking)
        #expect(event.touchedPath == nil)
    }

    @Test
    func largeWritePayloadStillForwardsTouchedPath() throws {
        // Regression for the 64 KiB cap: a Write embeds the full file content in
        // tool_input, which for a real doc dwarfs 64 KiB. The path must survive.
        let temp = try Self.temporaryEventFile()
        defer { temp.remove() }

        let bigContent = String(repeating: "a", count: 256 * 1024)
        let payload =
            #"{"hook_event_name":"PostToolUse","tool_name":"Write","tool_input":{"file_path":"/Users/agent/plan.md","content":"\#(bigContent)"}}"#
        #expect(payload.utf8.count > 64 * 1024)
        #expect(payload.utf8.count <= AgentHookCommand.maximumInputByteCount)

        let status = AgentHookCommand.run(
            arguments: ["--provider", "claude-code"],
            environment: ["AWESOMUX_AGENT_EVENT_FILE": temp.file.path],
            stdin: Data(payload.utf8)
        )

        #expect(status == 0)
        let event = try #require(try Self.readSingleEvent(from: temp.file))
        #expect(event.touchedPath == "/Users/agent/plan.md")
    }

    /// The lifecycle transition is load-bearing and the id is not: a hostile id
    /// must cost only itself, never the whole event.
    @Test(
        arguments: [
            "\(UUID().uuidString)\nrm -rf ~",
            "../../../tmp/evil",
            String(repeating: "a", count: 512),
            "not-a-uuid",
        ]
    )
    func hostileSessionIDIsStrippedButTheEventSurvives(rawSessionID: String) throws {
        let temp = try Self.temporaryEventFile()
        defer { temp.remove() }
        let eventFile = temp.file

        let payload = try JSONSerialization.data(
            withJSONObject: ["hook_event_name": "SessionStart", "session_id": rawSessionID]
        )
        let status = AgentHookCommand.run(
            arguments: ["--provider", "claude-code"],
            environment: ["AWESOMUX_AGENT_EVENT_FILE": eventFile.path],
            stdin: payload
        )

        #expect(status == 0)
        let parsedEvent = try #require(try Self.readSingleEvent(from: eventFile))
        #expect(parsedEvent.source == .claudeCode)
        #expect(parsedEvent.phase == .sessionStart)
        #expect(parsedEvent.executionState == .idle)
        #expect(parsedEvent.providerSessionID == nil)
    }

    /// The same rule one type-level deeper. `hostileSessionIDIsStrippedButTheEventSurvives`
    /// covers a well-typed String that fails validation; this covers a value
    /// that is not a String at all, which throws out of `Decodable` rather than
    /// failing a check. `AgentHookPayload` is the WRITE end — the earliest of
    /// the four boundaries this field crosses — so a throw here loses the event
    /// before it is ever appended, and nothing downstream can recover it.
    /// Encoded as raw JSON text rather than via `JSONSerialization`, because
    /// swift-testing requires `arguments:` elements to be `Sendable` and `Any`
    /// is not.
    @Test(
        arguments: [
            "42",
            "[\"a\"]",
            "{\"id\":\"a\"}",
            "true",
        ]
    )
    func wrongTypedSessionIDStripsTheFieldNotTheEvent(rawSessionIDJSON: String) throws {
        let temp = try Self.temporaryEventFile()
        defer { temp.remove() }
        let eventFile = temp.file

        let payload = Data(
            """
            {"hook_event_name": "SessionStart", "session_id": \(rawSessionIDJSON)}
            """.utf8
        )
        let status = AgentHookCommand.run(
            arguments: ["--provider", "claude-code"],
            environment: ["AWESOMUX_AGENT_EVENT_FILE": eventFile.path],
            stdin: payload
        )

        #expect(status == 0)
        let parsedEvent = try #require(try Self.readSingleEvent(from: eventFile))
        #expect(parsedEvent.source == .claudeCode)
        #expect(parsedEvent.phase == .sessionStart)
        #expect(parsedEvent.providerSessionID == nil)
    }

    /// The fallthrough the `try?` form has to preserve. A wrong-typed
    /// `session_id` must not consume the lookup — the legacy `sessionId`
    /// spelling still has to be reached. Neither the wrong-type test above nor
    /// the legacy-spelling tests cover this combination on their own, and a
    /// plausible-looking coalescing chain can short-circuit here.
    @Test
    func aWrongTypedSessionIDStillFallsThroughToTheLegacySpelling() throws {
        let temp = try Self.temporaryEventFile()
        defer { temp.remove() }
        let eventFile = temp.file

        let status = AgentHookCommand.run(
            arguments: ["--provider", "grok"],
            environment: ["AWESOMUX_AGENT_EVENT_FILE": eventFile.path],
            stdin: Data(
                #"{"hookEventName":"UserPromptSubmit","session_id":42,"sessionId":"parent-session"}"#
                    .utf8
            )
        )

        #expect(status == 0)
        let parsedEvent = try #require(try Self.readSingleEvent(from: eventFile))
        #expect(parsedEvent.providerSessionID == "parent-session")
    }

    @Test
    func outputDoesNotIncludeSensitiveInputKeys() throws {
        let temp = try Self.temporaryEventFile()
        defer { temp.remove() }
        let eventFile = temp.file
        let sensitivePayload = Data(
            """
            {"hook_event_name":"PreToolUse","prompt":"secret","tool_input":{"path":"/tmp/secret"},"cwd":"/private","transcript_path":"/tmp/transcript","model":"x","cost_usd":12.3,"tokens":99,"assistant_text":"nope","progress":"hidden"}
            """.utf8)

        _ = AgentHookCommand.run(
            arguments: ["--provider", "claude-code"],
            environment: ["AWESOMUX_AGENT_EVENT_FILE": eventFile.path],
            stdin: sensitivePayload
        )

        let output = try String(contentsOf: eventFile, encoding: .utf8)
        #expect(output.contains("prompt") == false)
        #expect(output.contains("tool_input") == false)
        #expect(output.contains("cwd") == false)
        #expect(output.contains("transcript_path") == false)
        #expect(output.contains("model") == false)
        #expect(output.contains("cost") == false)
        #expect(output.contains("tokens") == false)
        #expect(output.contains("assistant_text") == false)
        #expect(output.contains("progress") == false)
    }

    @Test(arguments: [
        Data("{".utf8),
        Data("{}".utf8),
        Data(#"{"hook_event_name":"UnknownEvent"}"#.utf8),
        Data(#"{"hook_event_name":"PreCompact"}"#.utf8),
        Data(#"{"hook_event_name":"PostCompact"}"#.utf8),
    ])
    func invalidOrSilentCodexInputWritesNothing(stdin: Data) throws {
        let temp = try Self.temporaryEventFile()
        defer { temp.remove() }
        let eventFile = temp.file

        let status = AgentHookCommand.run(
            arguments: ["--provider", "codex"],
            environment: ["AWESOMUX_AGENT_EVENT_FILE": eventFile.path],
            stdin: stdin
        )

        #expect(status == 0)
        #expect(try Data(contentsOf: eventFile).isEmpty)
    }

    @Test
    func missingEventFileEnvironmentWritesNothing() throws {
        let status = AgentHookCommand.run(
            arguments: ["--provider", "codex"],
            environment: [:],
            stdin: Self.hookPayload("SessionStart")
        )

        #expect(status == 0)
    }

    @Test(arguments: [
        [],
        ["--provider"],
        ["--provider", "gemini"],
        ["--source", "codex"],
        ["--provider", "codex", "--phase", "toolStart"],
    ])
    func invalidArgumentsExitSuccessAndWriteNothing(arguments: [String]) throws {
        let temp = try Self.temporaryEventFile()
        defer { temp.remove() }
        let eventFile = temp.file

        let status = AgentHookCommand.run(
            arguments: arguments,
            environment: ["AWESOMUX_AGENT_EVENT_FILE": eventFile.path],
            stdin: Self.hookPayload("SessionStart")
        )

        #expect(status == 0)
        #expect(try Data(contentsOf: eventFile).isEmpty)
    }

    @Test(arguments: [
        ["open-document"],
        ["open-document", "--provider", "gemini", "/tmp/notes.md"],
        ["open-document", "--source", "codex", "/tmp/notes.md"],
        ["open-document", "--provider", "codex"],
        ["open-document", "--provider", "codex", "/tmp/notes.md", "extra"],
    ])
    func invalidOpenDocumentArgumentsWriteNothing(arguments: [String]) throws {
        let temp = try Self.temporaryEventFile()
        defer { temp.remove() }
        let eventFile = temp.file

        let status = AgentHookCommand.run(
            arguments: arguments,
            environment: ["AWESOMUX_AGENT_EVENT_FILE": eventFile.path],
            stdin: Data()
        )

        #expect(status == 0)
        #expect(try Data(contentsOf: eventFile).isEmpty)
    }

    @Test(arguments: [
        "notes.md",
        "/tmp/notes.txt",
        "/tmp/notes.md\u{0}suffix",
    ])
    func invalidOpenDocumentPathsWriteNothing(path: String) throws {
        let temp = try Self.temporaryEventFile()
        defer { temp.remove() }
        let eventFile = temp.file

        let status = AgentHookCommand.run(
            arguments: ["open-document", "--provider", "codex", path],
            environment: ["AWESOMUX_AGENT_EVENT_FILE": eventFile.path],
            stdin: Data()
        )

        #expect(status == 0)
        #expect(try Data(contentsOf: eventFile).isEmpty)
    }

    @Test
    func oversizedOpenDocumentPayloadWritesNothing() throws {
        let temp = try Self.temporaryEventFile()
        defer { temp.remove() }
        let eventFile = temp.file
        let path = "/" + String(repeating: "a", count: AgentRuntimeEvent.maximumLineByteCount) + ".md"

        let status = AgentHookCommand.run(
            arguments: ["open-document", "--provider", "codex", path],
            environment: ["AWESOMUX_AGENT_EVENT_FILE": eventFile.path],
            stdin: Data()
        )

        #expect(status == 0)
        #expect(try Data(contentsOf: eventFile).isEmpty)
    }

    @Test
    func oversizedInputWritesNothing() throws {
        let temp = try Self.temporaryEventFile()
        defer { temp.remove() }
        let eventFile = temp.file
        let oversized = Data(repeating: UInt8(ascii: "x"), count: AgentHookCommand.maximumInputByteCount + 1)

        let status = AgentHookCommand.run(
            arguments: ["--provider", "claude-code"],
            environment: ["AWESOMUX_AGENT_EVENT_FILE": eventFile.path],
            stdin: oversized
        )

        #expect(status == 0)
        #expect(try Data(contentsOf: eventFile).isEmpty)
    }

    @Test
    func missingEventFileWritesNothing() throws {
        let temp = try Self.temporaryEventFile(createFile: false)
        defer { temp.remove() }
        let eventFile = temp.file

        let status = AgentHookCommand.run(
            arguments: ["--provider", "claude-code"],
            environment: ["AWESOMUX_AGENT_EVENT_FILE": eventFile.path],
            stdin: Self.hookPayload("SessionStart")
        )

        #expect(status == 0)
        #expect(!FileManager.default.fileExists(atPath: eventFile.path))
    }

    @Test
    func concurrentHookRunsAppendCompleteLines() throws {
        let temp = try Self.temporaryEventFile()
        defer { temp.remove() }
        let eventFile = temp.file
        let payload = Self.hookPayload("PermissionRequest")
        let environment = ["AWESOMUX_AGENT_EVENT_FILE": eventFile.path]

        DispatchQueue.concurrentPerform(iterations: 50) { _ in
            _ = AgentHookCommand.run(
                arguments: ["--provider", "codex"],
                environment: environment,
                stdin: payload
            )
        }

        let output = try Data(contentsOf: eventFile)
        let lines = output.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        #expect(lines.count == 50)

        for line in lines {
            #expect(AgentRuntimeEvent.parse(data: Data(line)) != nil)
        }
    }

    @Test
    func unwritableEventFileExitsSuccess() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "awesomux-agent-hook-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let status = AgentHookCommand.run(
            arguments: ["--provider", "claude-code"],
            environment: ["AWESOMUX_AGENT_EVENT_FILE": directory.path],
            stdin: Self.hookPayload("SessionStart")
        )

        #expect(status == 0)
    }

    @Test
    func symlinkEventFileExitsSuccessAndDoesNotWriteTarget() throws {
        let temp = try Self.temporaryEventFile(createFile: false)
        defer { temp.remove() }
        let target = temp.directory.appending(path: "target.jsonl")
        try Data("sentinel".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: temp.file, withDestinationURL: target)

        let status = AgentHookCommand.run(
            arguments: ["--provider", "claude-code"],
            environment: ["AWESOMUX_AGENT_EVENT_FILE": temp.file.path],
            stdin: Self.hookPayload("SessionStart")
        )

        #expect(status == 0)
        #expect(try String(contentsOf: target, encoding: .utf8) == "sentinel")
    }

    @Test
    func wrongOwnerValidationFails() throws {
        let wrongOwner = AgentHookEventFileAppender.FileInfo(
            isRegularFile: true,
            ownerUID: geteuid() + 1
        )

        #expect(throws: POSIXError.self) {
            try AgentHookEventFileAppender.validate(
                fileInfo: wrongOwner,
                effectiveUID: geteuid()
            )
        }
    }

    @Test
    func nonRegularValidationFails() throws {
        let directoryInfo = AgentHookEventFileAppender.FileInfo(
            isRegularFile: false,
            ownerUID: geteuid()
        )

        #expect(throws: POSIXError.self) {
            try AgentHookEventFileAppender.validate(
                fileInfo: directoryInfo,
                effectiveUID: geteuid()
            )
        }
    }

    private static func hookPayload(
        _ hookEventName: String,
        notificationType: String? = nil,
        providerSessionID: String? = nil,
        providerSessionKey: String = "sessionId",
        reason: String? = nil
    ) -> Data {
        var payload = #"{"hook_event_name":"\#(hookEventName)""#
        if let notificationType {
            payload += #","notification_type":"\#(notificationType)""#
        }
        if let providerSessionID {
            payload += #","\#(providerSessionKey)":"\#(providerSessionID)""#
        }
        if let reason {
            payload += #","reason":"\#(reason)""#
        }
        payload += "}"
        return Data(payload.utf8)
    }

    private static func postToolUsePayload(toolName: String, filePath: String) -> Data {
        let object: [String: Any] = [
            "hook_event_name": "PostToolUse",
            "tool_name": toolName,
            "tool_input": ["file_path": filePath],
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    private static func temporaryEventFile(createFile: Bool = true) throws -> TemporaryEventFile {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "awesomux-agent-hook-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "events.jsonl")
        if createFile {
            _ = FileManager.default.createFile(atPath: file.path, contents: nil)
        }
        return TemporaryEventFile(directory: directory, file: file)
    }

    private static func readSingleEvent(from file: URL) throws -> AgentRuntimeEvent? {
        let data = try Data(contentsOf: file)
        return AgentRuntimeEvent.parse(data: data.trimmingTrailingNewline())
    }

    private static func readEvents(from file: URL) throws -> [AgentRuntimeEvent] {
        try String(contentsOf: file, encoding: .utf8)
            .split(separator: "\n")
            .compactMap { AgentRuntimeEvent.parse(data: Data($0.utf8)) }
    }
}

private struct TemporaryEventFile {
    let directory: URL
    let file: URL

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private extension Data {
    func trimmingTrailingNewline() -> Data {
        var copy = self
        if copy.last == 0x0a {
            copy.removeLast()
        }
        return copy
    }
}
