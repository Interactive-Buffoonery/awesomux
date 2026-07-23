import AwesoMuxBridgeProtocol
import Foundation
import Testing
@testable import AwesoMuxCore

@Suite
struct AgentRuntimeEventTests {
    @Test
    func validClaudeEventParses() {
        let event = AgentRuntimeEvent.parse(
            line: #"{"v":1,"source":"claude-code","kind":"Claude Code","state":"thinking","phase":"toolStart","eventID":"abc123"}"#
        )

        #expect(event?.version == 1)
        #expect(event?.source == .claudeCode)
        #expect(event?.kind == .claudeCode)
        #expect(event?.state == .thinking)
        #expect(event?.phase == .toolStart)
        #expect(event?.eventID == "abc123")
    }

    @Test
    func executionAndAttentionFieldsParse() {
        let event = AgentRuntimeEvent.parse(
            line: #"{"v":1,"source":"codex","execution":"waiting","attentionReason":"permissionPrompt"}"#
        )

        #expect(event?.source == .codex)
        #expect(event?.executionState == .waiting)
        #expect(event?.attentionReason == .permissionPrompt)
        #expect(event?.state == nil)
    }

    @Test
    func unknownAttentionReasonParsesAsUnknown() {
        let event = AgentRuntimeEvent.parse(
            line: #"{"v":1,"source":"codex","execution":"waiting","attentionReason":"futureReason"}"#
        )

        #expect(event?.executionState == .waiting)
        #expect(event?.attentionReason == .unknown)
    }

    @Test
    func missingOptionalFieldsParse() {
        let event = AgentRuntimeEvent.parse(line: #"{"v":1,"source":"codex"}"#)

        #expect(event?.source == .codex)
        #expect(event?.kind == nil)
        #expect(event?.state == nil)
        #expect(event?.phase == nil)
        #expect(event?.eventID == nil)
        #expect(event?.timestamp == nil)
    }

    @Test
    func openDocumentEventParsesAbsoluteMarkdownPath() {
        let event = AgentRuntimeEvent.parse(
            line: #"{"v":1,"source":"codex","phase":"open-document","documentPath":"/tmp/notes.markdown"}"#
        )

        #expect(event?.source == .codex)
        #expect(event?.phase == .openDocument)
        #expect(event?.documentPath == "/tmp/notes.markdown")
    }

    @Test(arguments: [
        #"{"v":1,"source":"codex","phase":"open-document"}"#,
        #"{"v":1,"source":"codex","phase":"open-document","documentPath":"notes.md"}"#,
        #"{"v":1,"source":"codex","phase":"open-document","documentPath":"/tmp/notes.txt"}"#,
        #"{"v":1,"source":"codex","phase":"open-document","documentPath":"/tmp/notes.md\u0000suffix"}"#
    ])
    func invalidOpenDocumentEventsAreRejected(line: String) {
        #expect(AgentRuntimeEvent.parse(line: line) == nil)
    }

    @Test
    func nonOpenDocumentEventIgnoresDocumentPath() {
        let event = AgentRuntimeEvent.parse(
            line: #"{"v":1,"source":"codex","phase":"stop","documentPath":"/tmp/notes.md"}"#
        )

        #expect(event?.phase == .stop)
        #expect(event?.documentPath == nil)
    }

    @Test
    func unknownSourceFallsBackToUnknown() {
        let event = AgentRuntimeEvent.parse(line: #"{"v":1,"source":"gemini","state":"thinking"}"#)

        #expect(event?.source == .unknown)
        #expect(event?.state == .thinking)
    }

    @Test
    func malformedJSONReturnsNil() {
        #expect(AgentRuntimeEvent.parse(line: #"{"v":1,"source":"claude-code""#) == nil)
    }

    @Test
    func unsupportedVersionReturnsNil() {
        #expect(AgentRuntimeEvent.parse(line: #"{"v":2,"source":"claude-code"}"#) == nil)
    }

    @Test
    func unknownStateReturnsNil() {
        #expect(AgentRuntimeEvent.parse(line: #"{"v":1,"source":"claude-code","state":"blocked"}"#) == nil)
    }

    @Test
    func unknownExecutionReturnsNil() {
        #expect(AgentRuntimeEvent.parse(line: #"{"v":1,"source":"codex","execution":"blocked"}"#) == nil)
    }

    @Test
    func unknownKindReturnsNil() {
        #expect(AgentRuntimeEvent.parse(line: #"{"v":1,"source":"claude-code","kind":"Claude"}"#) == nil)
    }

    @Test
    func oversizedLineReturnsNil() {
        let oversized = #"{"v":1,"source":"claude-code","eventID":""#
            + String(repeating: "x", count: AgentRuntimeEvent.maximumLineByteCount)
            + #""}"#

        #expect(AgentRuntimeEvent.parse(line: oversized) == nil)
    }

    @Test
    func unknownExtraFieldsAreIgnored() {
        let event = AgentRuntimeEvent.parse(
            line: #"{"v":1,"source":"opencode","extra":"ignored","state":"waiting"}"#
        )

        #expect(event?.source == .openCode)
        #expect(event?.state == .waiting)
    }

    @Test
    func piSourceParses() {
        let event = AgentRuntimeEvent.parse(line: #"{"v":1,"source":"pi","state":"waiting"}"#)

        #expect(event?.source == .pi)
        #expect(event?.state == .waiting)
    }

    @Test
    func grokSourceAndProviderSessionIDParse() {
        let event = AgentRuntimeEvent.parse(
            line: #"{"v":1,"source":"grok","kind":"Grok","providerSessionID":"grok-parent","execution":"thinking"}"#
        )

        #expect(event?.source == .grok)
        #expect(event?.kind == .grok)
        #expect(event?.providerSessionID == "grok-parent")
        #expect(event?.executionState == .thinking)
    }

    @Test(arguments: [
        ("OpenCode", AgentKind.openCode),
        ("Pi", .pi)
    ])
    func localAgentKindsParse(rawKind: String, kind: AgentKind) {
        let event = AgentRuntimeEvent.parse(
            line: #"{"v":1,"source":"opencode","kind":"\#(rawKind)"}"#
        )

        #expect(event?.kind == kind)
    }

    @Test
    func boundaryLineAtMaximumByteCountParses() {
        // Build a payload whose UTF-8 byte length is exactly maximumLineByteCount.
        let prefix = #"{"v":1,"source":"claude-code","eventID":""#
        let suffix = #""}"#
        let padding = AgentRuntimeEvent.maximumLineByteCount
            - prefix.lengthOfBytes(using: .utf8)
            - suffix.lengthOfBytes(using: .utf8)
        let line = prefix + String(repeating: "x", count: padding) + suffix

        #expect(line.lengthOfBytes(using: .utf8) == AgentRuntimeEvent.maximumLineByteCount)
        #expect(AgentRuntimeEvent.parse(line: line) != nil)
    }

    @Test
    func epochSecondsTimestampParses() {
        let event = AgentRuntimeEvent.parse(
            line: #"{"v":1,"source":"claude-code","timestamp":1700000000}"#
        )

        #expect(event?.timestamp == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test
    func iso8601FractionalTimestampParses() {
        let event = AgentRuntimeEvent.parse(
            line: #"{"v":1,"source":"claude-code","timestamp":"2026-05-15T17:34:37.123Z"}"#
        )

        #expect(event?.timestamp != nil)
    }

    @Test
    func iso8601PlainTimestampParses() {
        let event = AgentRuntimeEvent.parse(
            line: #"{"v":1,"source":"claude-code","timestamp":"2026-05-15T17:34:37Z"}"#
        )

        #expect(event?.timestamp != nil)
    }

    @Test
    func garbageTimestampRejectsEvent() {
        let event = AgentRuntimeEvent.parse(
            line: #"{"v":1,"source":"claude-code","timestamp":"yesterday"}"#
        )

        #expect(event == nil)
    }

    @Test
    func inferredAgentKindMapsKnownSources() {
        #expect(AgentRuntimeSource.claudeCode.inferredAgentKind == .claudeCode)
        #expect(AgentRuntimeSource.codex.inferredAgentKind == .codex)
        #expect(AgentRuntimeSource.openCode.inferredAgentKind == .openCode)
        #expect(AgentRuntimeSource.pi.inferredAgentKind == .pi)
        #expect(AgentRuntimeSource.grok.inferredAgentKind == .grok)
        #expect(AgentRuntimeSource.unknown.inferredAgentKind == nil)
    }

    // MARK: - assertsWaitingExecutionState (AgentPromptGate trust-stamp gate,
    // INT-569 follow-up / review finding)

    @Test("modern executionState: waiting asserts")
    func modernExecutionStateWaitingAsserts() {
        let event = AgentRuntimeEvent(source: .claudeCode, executionState: .waiting)
        #expect(event.assertsWaitingExecutionState)
    }

    @Test("legacy state field's executionState: waiting asserts")
    func legacyStateWaitingAsserts() {
        let event = AgentRuntimeEvent(source: .codex, state: .waiting)
        #expect(event.assertsWaitingExecutionState)
    }

    @Test(
        "a title-only rename, an openDocument event, and a non-waiting execution state never assert waiting",
        arguments: [
            AgentRuntimeEvent(source: .claudeCode, phase: .rename, title: "renamed"),
            AgentRuntimeEvent(source: .claudeCode, phase: .openDocument, documentPath: "/tmp/a.md"),
            AgentRuntimeEvent(source: .codex, executionState: .thinking),
            AgentRuntimeEvent(source: .codex, phase: .toolStart),
            AgentRuntimeEvent(source: .claudeCode),
        ]
    )
    func nonAssertingEventsNeverAssertWaiting(event: AgentRuntimeEvent) {
        // This is the exact review finding: an accepted event that carries
        // neither `executionState` nor `state` (a rename, a tool-lifecycle
        // ping, a bare same-state repeat) must never read as an authoritative
        // waiting assertion, even though the PANE it lands on might already be
        // `.waiting` from an earlier, genuinely-asserting event.
        #expect(!event.assertsWaitingExecutionState)
    }
}
