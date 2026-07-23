import AwesoMuxBridgeProtocol
import Foundation
import Darwin
import Testing
@testable import AwesoMuxAgentHookSupport
@testable import AwesoMuxCore

@Suite
struct AgentHookCommandTests {
    @Test
    func mappedEventWritesParseableRuntimeEvent() throws {
        let temp = try Self.temporaryEventFile()
        defer { temp.remove() }
        let eventFile = temp.file

        let status = AgentHookCommand.run(
            arguments: ["--provider", "codex"],
            environment: ["AWESOMUX_AGENT_EVENT_FILE": eventFile.path],
            stdin: Self.hookPayload("PermissionRequest")
        )

        #expect(status == 0)
        let parsedEvent = try Self.readSingleEvent(from: eventFile)
        let event: AgentRuntimeEvent = try #require(parsedEvent)
        #expect(event.source == AgentRuntimeSource.codex)
        #expect(event.kind == AgentKind.codex)
        #expect(event.executionState == nil)
        #expect(event.attentionReason == AttentionReason.permissionPrompt)
        #expect(event.phase == AgentRuntimePhase.notification)
        #expect(event.eventID?.isEmpty == false)
        #expect(event.timestamp != nil)
    }

    @Test
    func openDocumentWritesParseableRuntimeEvent() throws {
        let temp = try Self.temporaryEventFile()
        defer { temp.remove() }
        let eventFile = temp.file

        let status = AgentHookCommand.run(
            arguments: ["open-document", "--provider", "codex", "/tmp/notes.md"],
            environment: ["AWESOMUX_AGENT_EVENT_FILE": eventFile.path],
            stdin: Data(repeating: UInt8(ascii: "x"), count: AgentHookCommand.maximumInputByteCount + 1)
        )

        #expect(status == 0)
        let raw = try Data(contentsOf: eventFile)
        let json = try #require(JSONSerialization.jsonObject(with: raw.trimmingTrailingNewline()) as? [String: Any])
        #expect(json["documentPath"] as? String == "/tmp/notes.md")
        let event = try #require(AgentRuntimeEvent.parse(data: raw.trimmingTrailingNewline()))
        #expect(event.source == .codex)
        #expect(event.kind == .codex)
        #expect(event.phase == .openDocument)
        #expect(event.documentPath == "/tmp/notes.md")
        #expect(event.executionState == nil)
        #expect(event.attentionReason == nil)
        #expect(event.state == nil)
        #expect(event.eventID?.isEmpty == false)
        #expect(event.timestamp != nil)
    }

    @Test
    func openDocumentSkipsStandardInputRead() {
        #expect(
            AgentHookCommand.shouldReadStandardInput(
                arguments: ["open-document", "--provider", "codex", "/tmp/notes.md"]
            ) == false)
    }

    // MARK: - Touched-path forwarding (issue #175)

    @Test(arguments: ["Write", "Edit", "MultiEdit"])
    func claudeCodePostToolUseForwardsMarkdownTouchedPath(tool: String) throws {
        let temp = try Self.temporaryEventFile()
        defer { temp.remove() }

        let status = AgentHookCommand.run(
            arguments: ["--provider", "claude-code"],
            environment: ["AWESOMUX_AGENT_EVENT_FILE": temp.file.path],
            stdin: Self.postToolUsePayload(toolName: tool, filePath: "/Users/agent/plan.md")
        )

        #expect(status == 0)
        let event = try #require(try Self.readSingleEvent(from: temp.file))
        #expect(event.source == .claudeCode)
        #expect(event.phase == .toolEnd)
        #expect(event.executionState == .thinking)
        #expect(event.touchedPath == "/Users/agent/plan.md")
    }

    @Test
    func nonMutatingToolDoesNotForwardTouchedPath() throws {
        let temp = try Self.temporaryEventFile()
        defer { temp.remove() }

        let status = AgentHookCommand.run(
            arguments: ["--provider", "claude-code"],
            environment: ["AWESOMUX_AGENT_EVENT_FILE": temp.file.path],
            stdin: Self.postToolUsePayload(toolName: "Read", filePath: "/Users/agent/plan.md")
        )

        #expect(status == 0)
        let event = try #require(try Self.readSingleEvent(from: temp.file))
        #expect(event.phase == .toolEnd)
        #expect(event.touchedPath == nil)
    }

    @Test(arguments: [
        "/Users/agent/main.swift",  // non-Markdown extension
        "relative/notes.md",  // not absolute
        "/Users/agent/re\u{202e}port.md",  // bidi-override scalar
        "/Users/agent/#175.md",  // `#` misparses as a link fragment
        "/Users/agent/a?b.md",  // `?` misparses as a link query
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

    @Test
    func preToolUseDoesNotForwardTouchedPath() throws {
        let temp = try Self.temporaryEventFile()
        defer { temp.remove() }

        let status = AgentHookCommand.run(
            arguments: ["--provider", "claude-code"],
            environment: ["AWESOMUX_AGENT_EVENT_FILE": temp.file.path],
            stdin: Data(
                #"{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"/Users/agent/plan.md"}}"#.utf8
            )
        )

        #expect(status == 0)
        let event = try #require(try Self.readSingleEvent(from: temp.file))
        #expect(event.phase == .toolStart)
        #expect(event.touchedPath == nil)
    }

    @Test
    func codexPostToolUseDoesNotForwardTouchedPath() throws {
        let temp = try Self.temporaryEventFile()
        defer { temp.remove() }

        let status = AgentHookCommand.run(
            arguments: ["--provider", "codex"],
            environment: ["AWESOMUX_AGENT_EVENT_FILE": temp.file.path],
            stdin: Self.postToolUsePayload(toolName: "Write", filePath: "/Users/agent/plan.md")
        )

        #expect(status == 0)
        let event = try #require(try Self.readSingleEvent(from: temp.file))
        #expect(event.touchedPath == nil)
    }

    @Test
    func malformedToolNameDoesNotSinkTheEvent() throws {
        // A present-but-wrong-type tool_name must not throw out of the payload
        // decode and drop the event's lifecycle transition — it only gates
        // touched-path forwarding.
        let temp = try Self.temporaryEventFile()
        defer { temp.remove() }

        let status = AgentHookCommand.run(
            arguments: ["--provider", "claude-code"],
            environment: ["AWESOMUX_AGENT_EVENT_FILE": temp.file.path],
            stdin: Data(
                #"{"hook_event_name":"PostToolUse","tool_name":123,"tool_input":{"file_path":"/Users/agent/plan.md"}}"#.utf8
            )
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

    @Test(arguments: [
        ("opencode", AgentRuntimeSource.openCode, AgentKind.openCode),
        ("pi", .pi, .pi),
    ])
    func localAgentProvidersWriteProviderIdentity(
        provider: String,
        source: AgentRuntimeSource,
        kind: AgentKind
    ) throws {
        let temp = try Self.temporaryEventFile()
        defer { temp.remove() }
        let eventFile = temp.file

        let status = AgentHookCommand.run(
            arguments: ["--provider", provider],
            environment: ["AWESOMUX_AGENT_EVENT_FILE": eventFile.path],
            stdin: Self.hookPayload("SessionStart")
        )

        #expect(status == 0)
        let parsedEvent = try #require(try Self.readSingleEvent(from: eventFile))
        #expect(parsedEvent.source == source)
        #expect(parsedEvent.kind == kind)
        #expect(parsedEvent.executionState == .idle)
        #expect(parsedEvent.phase == .sessionStart)
    }

    @Test(arguments: [
        ("Notification", Optional("permission_prompt"), AgentExecutionState?.none, AttentionReason.permissionPrompt),
        ("Notification", Optional("idle_prompt"), Optional(AgentExecutionState.waiting), nil),
        ("Notification", Optional<String>.none, AgentExecutionState?.none, AttentionReason.userInputRequired),
        ("PermissionRequest", Optional<String>.none, AgentExecutionState?.none, AttentionReason.permissionPrompt),
        ("StopFailure", Optional<String>.none, Optional(AgentExecutionState.error), nil),
    ])
    func claudeSpecificHookPayloadsWriteCurrentContract(
        hookEventName: String,
        notificationType: String?,
        executionState: AgentExecutionState?,
        attentionReason: AttentionReason?
    ) throws {
        let temp = try Self.temporaryEventFile()
        defer { temp.remove() }
        let eventFile = temp.file

        let status = AgentHookCommand.run(
            arguments: ["--provider", "claude-code"],
            environment: ["AWESOMUX_AGENT_EVENT_FILE": eventFile.path],
            stdin: Self.hookPayload(hookEventName, notificationType: notificationType)
        )

        #expect(status == 0)
        let parsedEvent = try #require(try Self.readSingleEvent(from: eventFile))
        #expect(parsedEvent.source == .claudeCode)
        #expect(parsedEvent.kind == .claudeCode)
        #expect(parsedEvent.executionState == executionState)
        #expect(parsedEvent.attentionReason == attentionReason)
        #expect(parsedEvent.phase == (hookEventName == "StopFailure" ? .stop : .notification))
    }

    @Test(arguments: [
        ("SubagentStart", AgentRuntimePhase.toolStart),
        ("SubagentStop", .toolEnd),
    ])
    func codexSubagentEventsWriteToolPhases(
        hookEventName: String,
        phase: AgentRuntimePhase
    ) throws {
        let temp = try Self.temporaryEventFile()
        defer { temp.remove() }
        let eventFile = temp.file

        let status = AgentHookCommand.run(
            arguments: ["--provider", "codex"],
            environment: ["AWESOMUX_AGENT_EVENT_FILE": eventFile.path],
            stdin: Self.hookPayload(hookEventName)
        )

        #expect(status == 0)
        let parsedEvent = try #require(try Self.readSingleEvent(from: eventFile))
        #expect(parsedEvent.source == .codex)
        #expect(parsedEvent.kind == .codex)
        #expect(parsedEvent.executionState == .thinking)
        #expect(parsedEvent.attentionReason == nil)
        #expect(parsedEvent.phase == phase)
    }

    @Test
    func grokCurrentUserPromptSubmitWithSessionIDWritesThinkingEvent() throws {
        let temp = try Self.temporaryEventFile()
        defer { temp.remove() }
        let eventFile = temp.file

        let status = AgentHookCommand.run(
            arguments: ["--provider", "grok"],
            environment: ["AWESOMUX_AGENT_EVENT_FILE": eventFile.path],
            stdin: Self.hookPayload(
                "UserPromptSubmit",
                providerSessionID: "parent-session",
                providerSessionKey: "session_id"
            )
        )

        #expect(status == 0)
        let parsedEvent = try #require(try Self.readSingleEvent(from: eventFile))
        #expect(parsedEvent.source == .grok)
        #expect(parsedEvent.kind == .grok)
        #expect(parsedEvent.executionState == .thinking)
        #expect(parsedEvent.attentionReason == nil)
        #expect(parsedEvent.phase == .promptSubmit)
        #expect(parsedEvent.providerSessionID == "parent-session")
    }

    @Test
    func grokCurrentStopWithSessionIDWritesWaitingEvent() throws {
        let temp = try Self.temporaryEventFile()
        defer { temp.remove() }
        let eventFile = temp.file

        let status = AgentHookCommand.run(
            arguments: ["--provider", "grok"],
            environment: ["AWESOMUX_AGENT_EVENT_FILE": eventFile.path],
            stdin: Self.hookPayload(
                "Stop",
                providerSessionID: "parent-session",
                providerSessionKey: "session_id"
            )
        )

        #expect(status == 0)
        let parsedEvent = try #require(try Self.readSingleEvent(from: eventFile))
        #expect(parsedEvent.source == .grok)
        #expect(parsedEvent.kind == .grok)
        #expect(parsedEvent.executionState == .waiting)
        #expect(parsedEvent.attentionReason == nil)
        #expect(parsedEvent.phase == .stop)
        #expect(parsedEvent.providerSessionID == "parent-session")
    }

    @Test
    func grokCamelHookEventNameWithSessionIdWritesThinkingEvent() throws {
        let temp = try Self.temporaryEventFile()
        defer { temp.remove() }
        let eventFile = temp.file

        let status = AgentHookCommand.run(
            arguments: ["--provider", "grok"],
            environment: ["AWESOMUX_AGENT_EVENT_FILE": eventFile.path],
            stdin: Data(
                #"{"hookEventName":"UserPromptSubmit","sessionId":"parent-session"}"#.utf8
            )
        )

        #expect(status == 0)
        let parsedEvent = try #require(try Self.readSingleEvent(from: eventFile))
        #expect(parsedEvent.source == .grok)
        #expect(parsedEvent.kind == .grok)
        #expect(parsedEvent.executionState == .thinking)
        #expect(parsedEvent.phase == .promptSubmit)
        #expect(parsedEvent.providerSessionID == "parent-session")
    }

    @Test
    func nonGrokCamelHookEventNameWritesNothing() throws {
        let temp = try Self.temporaryEventFile()
        defer { temp.remove() }
        let eventFile = temp.file

        let status = AgentHookCommand.run(
            arguments: ["--provider", "codex"],
            environment: ["AWESOMUX_AGENT_EVENT_FILE": eventFile.path],
            stdin: Data(#"{"hookEventName":"SessionStart"}"#.utf8)
        )

        #expect(status == 0)
        #expect(try Data(contentsOf: eventFile).isEmpty)
    }

    @Test
    func grokDocumentedHookEventNameShapeWritesRuntimeEvent() throws {
        let temp = try Self.temporaryEventFile()
        defer { temp.remove() }
        let eventFile = temp.file

        let status = AgentHookCommand.run(
            arguments: ["--provider", "grok"],
            environment: ["AWESOMUX_AGENT_EVENT_FILE": eventFile.path],
            stdin: Data(
                #"{"hookEventName":"pre_tool_use","sessionId":"parent-session"}"#.utf8
            )
        )

        #expect(status == 0)
        let parsedEvent = try #require(try Self.readSingleEvent(from: eventFile))
        #expect(parsedEvent.source == .grok)
        #expect(parsedEvent.kind == .grok)
        #expect(parsedEvent.executionState == .thinking)
        #expect(parsedEvent.phase == .toolStart)
        #expect(parsedEvent.providerSessionID == "parent-session")
    }

    @Test
    func grokPermissionDeniedWithSessionIDWritesErrorEvent() throws {
        let temp = try Self.temporaryEventFile()
        defer { temp.remove() }
        let eventFile = temp.file

        let status = AgentHookCommand.run(
            arguments: ["--provider", "grok"],
            environment: ["AWESOMUX_AGENT_EVENT_FILE": eventFile.path],
            stdin: Self.hookPayload(
                "PermissionDenied",
                providerSessionID: "parent-session",
                providerSessionKey: "session_id"
            )
        )

        #expect(status == 0)
        let parsedEvent = try #require(try Self.readSingleEvent(from: eventFile))
        #expect(parsedEvent.source == .grok)
        #expect(parsedEvent.kind == .grok)
        #expect(parsedEvent.executionState == .error)
        #expect(parsedEvent.attentionReason == nil)
        #expect(parsedEvent.phase == .notification)
        #expect(parsedEvent.providerSessionID == "parent-session")
    }

    @Test
    func grokSessionIDTakesPrecedenceOverLegacySessionId() throws {
        let temp = try Self.temporaryEventFile()
        defer { temp.remove() }
        let eventFile = temp.file

        let status = AgentHookCommand.run(
            arguments: ["--provider", "grok"],
            environment: ["AWESOMUX_AGENT_EVENT_FILE": eventFile.path],
            stdin: Data(
                #"{"hook_event_name":"SessionStart","session_id":"current-session","sessionId":"legacy-session"}"#.utf8
            )
        )

        #expect(status == 0)
        let parsedEvent = try #require(try Self.readSingleEvent(from: eventFile))
        #expect(parsedEvent.providerSessionID == "current-session")
        #expect(parsedEvent.phase == .sessionStart)
    }

    @Test
    func nonGrokSessionIDIsNotPersisted() throws {
        let temp = try Self.temporaryEventFile()
        defer { temp.remove() }
        let eventFile = temp.file

        let status = AgentHookCommand.run(
            arguments: ["--provider", "claude-code"],
            environment: ["AWESOMUX_AGENT_EVENT_FILE": eventFile.path],
            stdin: Data(
                #"{"hook_event_name":"SessionStart","session_id":"not-grok"}"#.utf8
            )
        )

        #expect(status == 0)
        let parsedEvent = try #require(try Self.readSingleEvent(from: eventFile))
        #expect(parsedEvent.source == .claudeCode)
        #expect(parsedEvent.phase == .sessionStart)
        #expect(parsedEvent.providerSessionID == nil)
    }

    @Test
    func grokLegacyStopWithEndTurnReasonWritesWaitingEvent() throws {
        let temp = try Self.temporaryEventFile()
        defer { temp.remove() }
        let eventFile = temp.file

        let status = AgentHookCommand.run(
            arguments: ["--provider", "grok"],
            environment: ["AWESOMUX_AGENT_EVENT_FILE": eventFile.path],
            stdin: Self.hookPayload("stop", providerSessionID: "parent-session", reason: "end_turn")
        )

        #expect(status == 0)
        let parsedEvent = try #require(try Self.readSingleEvent(from: eventFile))
        #expect(parsedEvent.source == .grok)
        #expect(parsedEvent.kind == .grok)
        #expect(parsedEvent.executionState == .waiting)
        #expect(parsedEvent.attentionReason == nil)
        #expect(parsedEvent.phase == .stop)
        #expect(parsedEvent.providerSessionID == "parent-session")
    }

    @Test
    func grokErrorReasonWritesErrorStop() throws {
        let temp = try Self.temporaryEventFile()
        defer { temp.remove() }
        let eventFile = temp.file

        let status = AgentHookCommand.run(
            arguments: ["--provider", "grok"],
            environment: ["AWESOMUX_AGENT_EVENT_FILE": eventFile.path],
            stdin: Self.hookPayload("stop", providerSessionID: "parent-session", reason: "cancel")
        )

        #expect(status == 0)
        let parsedEvent = try #require(try Self.readSingleEvent(from: eventFile))
        #expect(parsedEvent.source == .grok)
        #expect(parsedEvent.executionState == .error)
        #expect(parsedEvent.phase == .stop)
        #expect(parsedEvent.providerSessionID == "parent-session")
    }

    @Test
    func grokSnakeCaseSessionStartWritesProviderIdentity() throws {
        let temp = try Self.temporaryEventFile()
        defer { temp.remove() }
        let eventFile = temp.file

        let status = AgentHookCommand.run(
            arguments: ["--provider", "grok"],
            environment: ["AWESOMUX_AGENT_EVENT_FILE": eventFile.path],
            stdin: Self.hookPayload("session_start", providerSessionID: "parent-session")
        )

        #expect(status == 0)
        let parsedEvent = try #require(try Self.readSingleEvent(from: eventFile))
        #expect(parsedEvent.source == .grok)
        #expect(parsedEvent.kind == .grok)
        #expect(parsedEvent.executionState == .idle)
        #expect(parsedEvent.phase == .sessionStart)
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

    @Test
    func generatedTimestampHasSubsecondPrecision() throws {
        let temp = try Self.temporaryEventFile()
        defer { temp.remove() }
        let eventFile = temp.file

        _ = AgentHookCommand.run(
            arguments: ["--provider", "claude-code"],
            environment: ["AWESOMUX_AGENT_EVENT_FILE": eventFile.path],
            stdin: Self.hookPayload("SessionStart")
        )

        let raw = try Data(contentsOf: eventFile)
        let object = try #require(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        let timestamp = try #require(object["timestamp"] as? Double)
        #expect(timestamp.rounded(FloatingPointRoundingRule.down) != timestamp)
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

    @Test(arguments: [
        Data(#"{"hook_event_name":"UnknownEvent"}"#.utf8)
    ])
    func silentClaudeInputWritesNothing(stdin: Data) throws {
        let temp = try Self.temporaryEventFile()
        defer { temp.remove() }
        let eventFile = temp.file

        let status = AgentHookCommand.run(
            arguments: ["--provider", "claude-code"],
            environment: ["AWESOMUX_AGENT_EVENT_FILE": eventFile.path],
            stdin: stdin
        )

        #expect(status == 0)
        #expect(try Data(contentsOf: eventFile).isEmpty)
    }

    @Test("SessionEnd writes a resetting sessionEnd event with no attention")
    func sessionEndWritesResetEvent() throws {
        let temp = try Self.temporaryEventFile()
        defer { temp.remove() }
        let eventFile = temp.file

        let status = AgentHookCommand.run(
            arguments: ["--provider", "pi"],
            environment: ["AWESOMUX_AGENT_EVENT_FILE": eventFile.path],
            stdin: Self.hookPayload("SessionEnd")
        )

        #expect(status == 0)
        let parsedEvent = try #require(try Self.readSingleEvent(from: eventFile))
        #expect(parsedEvent.phase == .sessionEnd)
        #expect(parsedEvent.executionState == .idle)
        #expect(parsedEvent.attentionReason == nil)
    }

    @Test("Stop writes waiting without attention overlay")
    func stopWritesWaitingEvent() throws {
        let temp = try Self.temporaryEventFile()
        defer { temp.remove() }
        let eventFile = temp.file

        let status = AgentHookCommand.run(
            arguments: ["--provider", "codex"],
            environment: ["AWESOMUX_AGENT_EVENT_FILE": eventFile.path],
            stdin: Self.hookPayload("Stop")
        )

        #expect(status == 0)
        let parsedEvent = try #require(try Self.readSingleEvent(from: eventFile))
        #expect(parsedEvent.phase == .stop)
        #expect(parsedEvent.executionState == .waiting)
        #expect(parsedEvent.attentionReason == nil)
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
