import AwesoMuxBridgeProtocol
import Foundation
import Testing
@testable import AwesoMuxCore

@Suite
struct AgentRuntimeEventTests {
    @Test(arguments: [
        // Wrong source: only claude-code may carry a touched path today.
        #"{"v":1,"source":"grok","phase":"toolEnd","touchedPath":"/Users/agent/plan.md"}"#,
        #"{"v":1,"source":"codex","phase":"toolEnd","touchedPath":"/Users/agent/plan.md"}"#,
        // Wrong phase: a forged path on any non-toolEnd phase is stripped.
        #"{"v":1,"source":"claude-code","phase":"stop","touchedPath":"/Users/agent/plan.md"}"#,
        #"{"v":1,"source":"claude-code","phase":"notification","touchedPath":"/Users/agent/plan.md"}"#,
    ])
    func touchedPathStrippedOutsideClaudeToolEndScope(line: String) {
        let event = AgentRuntimeEvent.parse(line: line)
        // The event still parses; only the out-of-scope path is dropped.
        #expect(event != nil)
        #expect(event?.touchedPath == nil)
    }

    @Test(arguments: [
        #"{"v":1,"source":"claude-code","phase":"toolEnd","touchedPath":"notes.md"}"#,  // relative
        #"{"v":1,"source":"claude-code","phase":"toolEnd","touchedPath":"/tmp/notes.txt"}"#,  // non-markdown
        #"{"v":1,"source":"claude-code","phase":"toolEnd","touchedPath":"/tmp/notes.md\u0000x"}"#,  // NUL
        // `#` is legal in a filename but the recent-link open path strips it as a
        // fragment, reducing the path to its directory, so the file could never
        // open — dropped. (`?` is preserved and openable.)
        ##"{"v":1,"source":"claude-code","phase":"toolEnd","touchedPath":"/tmp/drafts/#175.md"}"##,
        // Wrong-typed touchedPath must strip the field, not throw and drop the
        // whole (lifecycle-bearing) event.
        ##"{"v":1,"source":"claude-code","phase":"toolEnd","touchedPath":["/tmp/notes.md"]}"##,
        ##"{"v":1,"source":"claude-code","phase":"toolEnd","touchedPath":42}"##,
        ##"{"v":1,"source":"claude-code","phase":"toolEnd","touchedPath":{"p":"/tmp/notes.md"}}"##,
        ##"{"v":1,"source":"claude-code","phase":"toolEnd","touchedPath":null}"##,
        #"{"v":1,"source":"claude-code","phase":"toolEnd","touchedPath":"/Users/agent/re\u202ereport.md"}"#,
    ])
    func invalidTouchedPathIsDroppedButEventSurvives(line: String) {
        let event = AgentRuntimeEvent.parse(line: line)
        #expect(event?.phase == .toolEnd)
        #expect(event?.touchedPath == nil)
    }

    @Test
    func oversizedLineReturnsNil() {
        let oversized =
            #"{"v":1,"source":"claude-code","eventID":""#
            + String(repeating: "x", count: AgentRuntimeEvent.maximumLineByteCount)
            + #""}"#

        #expect(AgentRuntimeEvent.parse(line: oversized) == nil)
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

    @Test(arguments: [
        #"{"v":1,"source":"codex","phase":"open-document"}"#,
        #"{"v":1,"source":"codex","phase":"open-document","documentPath":"notes.md"}"#,
        #"{"v":1,"source":"codex","phase":"open-document","documentPath":"/tmp/notes.txt"}"#,
        #"{"v":1,"source":"codex","phase":"open-document","documentPath":"/tmp/notes.md\u0000suffix"}"#,
        #"{"v":1,"source":"claude-code""#,
        #"{"v":2,"source":"claude-code"}"#,
        #"{"v":1,"source":"claude-code","state":"blocked"}"#,
        #"{"v":1,"source":"codex","execution":"blocked"}"#,
        #"{"v":1,"source":"claude-code","kind":"Claude"}"#,
        #"{"v":1,"source":"claude-code","timestamp":"yesterday"}"#,
    ])
    func rejectedLinesReturnNil(line: String) {
        #expect(AgentRuntimeEvent.parse(line: line) == nil)
    }
}
