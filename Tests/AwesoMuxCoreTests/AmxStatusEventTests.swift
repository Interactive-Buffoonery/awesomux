import Testing
@testable import AwesoMuxCore

@Suite("AmxStatusEvent")
struct AmxStatusEventTests {

    // MARK: - Wire fixtures

    let attachedLine = """
    {"event":"attached","token":"tok-abc","created":true,"daemon_pid":1234,"daemon_created_at":1700000000,"session":"ses-1","ts":1700000001}
    """

    let sessionEndLine = """
    {"event":"session-end","token":"tok-abc","reason":"shell-exit","code":0,"session":"ses-1","ts":1700000010}
    """

    // MARK: - Test 1: 2-line buffer (attached + session-end, correct token, trailing newline)

    @Test("parses two complete JSONL lines with correct token")
    func parseTwoCompleteLines() throws {
        let buffer = attachedLine + "\n" + sessionEndLine + "\n"
        let events = AmxStatusEvent.parseLines(buffer, expectedToken: "tok-abc")

        #expect(events.count == 2)

        // First event: attached
        guard case let .attached(created, daemonPid, daemonCreatedAt) = events[0].kind else {
            Issue.record("Expected .attached as first event")
            return
        }
        #expect(created == true)
        #expect(daemonPid == 1234)
        #expect(daemonCreatedAt == 1700000000)
        #expect(events[0].token == "tok-abc")
        #expect(events[0].session == "ses-1")

        // Second event: session-end
        guard case let .sessionEnd(reason, code) = events[1].kind else {
            Issue.record("Expected .sessionEnd as second event")
            return
        }
        #expect(reason == .shellExit)
        #expect(code == 0)
        #expect(events[1].token == "tok-abc")
        #expect(events[1].session == "ses-1")
    }

    // MARK: - Test 2: partial trailing line (no trailing newline) is ignored

    @Test("ignores partial trailing line with no trailing newline")
    func partialTrailingLineIgnored() {
        let complete = attachedLine + "\n"
        let partial = sessionEndLine // no trailing newline — simulates a mid-write kqueue fire
        let buffer = complete + partial

        let events = AmxStatusEvent.parseLines(buffer, expectedToken: "tok-abc")

        // Only the complete line should be parsed
        #expect(events.count == 1)
        guard case .attached = events[0].kind else {
            Issue.record("Expected .attached as first event")
            return
        }
    }

    // MARK: - Test 3: wrong token line is dropped

    @Test("drops lines with wrong token")
    func wrongTokenDropped() {
        let wrongToken = """
        {"event":"attached","token":"WRONG","created":false,"daemon_pid":9999,"daemon_created_at":1700000000,"session":"ses-x","ts":1700000001}
        """
        let buffer = wrongToken + "\n" + attachedLine + "\n"
        let events = AmxStatusEvent.parseLines(buffer, expectedToken: "tok-abc")

        // Only the correct-token line should pass
        #expect(events.count == 1)
        #expect(events[0].token == "tok-abc")
    }

    // MARK: - Test 4: garbage / non-JSON line is dropped without throwing

    @Test("drops malformed or non-JSON lines without throwing")
    func garbageLineDropped() {
        let buffer = "this is not json at all\n" + attachedLine + "\n"
        let events = AmxStatusEvent.parseLines(buffer, expectedToken: "tok-abc")

        #expect(events.count == 1)
    }

    // MARK: - Test 5: unknown reason string parses as .unknown

    @Test("unknown reason string maps to .unknown")
    func unknownReasonMapsToUnknown() {
        let line = """
        {"event":"session-end","token":"tok-abc","reason":"something-new","code":42,"session":"ses-2","ts":1700000020}
        """
        let events = AmxStatusEvent.parseLines(line + "\n", expectedToken: "tok-abc")

        #expect(events.count == 1)
        guard case let .sessionEnd(reason, code) = events[0].kind else {
            Issue.record("Expected .sessionEnd")
            return
        }
        #expect(reason == .unknown)
        #expect(code == 42)
    }

    // MARK: - Test 6: a session-end without a code preserves nil (not 0)

    @Test("session-end with no code field parses code as nil, not 0")
    func missingCodeParsesAsNil() {
        // 0 is the clean-exit sentinel; collapsing an absent code to 0 would make
        // the end policy read a code-less remote exit as clean and close the pane
        // instead of erroring (INT-769 safe default). The nil must survive decode.
        let line = """
        {"event":"session-end","token":"tok-abc","reason":"shell-exit","session":"ses-3","ts":1700000030}
        """
        let events = AmxStatusEvent.parseLines(line + "\n", expectedToken: "tok-abc")

        #expect(events.count == 1)
        guard case let .sessionEnd(reason, code) = events[0].kind else {
            Issue.record("Expected .sessionEnd")
            return
        }
        #expect(reason == .shellExit)
        #expect(code == nil)
    }

    // MARK: - Reason string mapping

    @Test("all known reason strings map correctly")
    func allReasonStringsMapCorrectly() {
        let cases: [(String, SessionEndReason)] = [
            ("daemon-died", .daemonDied),
            ("detached", .detached),
            ("shell-exit", .shellExit),
            ("unknown", .unknown),
        ]
        for (reasonStr, expected) in cases {
            let line = """
            {"event":"session-end","token":"tok-abc","reason":"\(reasonStr)","code":0,"session":"ses-1","ts":1700000000}
            """
            let events = AmxStatusEvent.parseLines(line + "\n", expectedToken: "tok-abc")
            #expect(events.count == 1, "Expected 1 event for reason '\(reasonStr)'")
            guard let event = events.first,
                  case let .sessionEnd(reason, _) = event.kind else { continue }
            #expect(reason == expected, "Mismatch for '\(reasonStr)'")
        }
    }

    // MARK: - Edge cases

    @Test("empty buffer returns empty array")
    func emptyBufferReturnsEmpty() {
        #expect(AmxStatusEvent.parseLines("", expectedToken: "tok-abc").isEmpty)
    }

    @Test("buffer with only a newline returns empty array")
    func newlineOnlyBufferReturnsEmpty() {
        #expect(AmxStatusEvent.parseLines("\n", expectedToken: "tok-abc").isEmpty)
    }

    @Test("created=false is preserved")
    func createdFalsePreserved() {
        let line = """
        {"event":"attached","token":"tok-abc","created":false,"daemon_pid":5678,"daemon_created_at":1700000000,"session":"ses-3","ts":1700000001}
        """
        let events = AmxStatusEvent.parseLines(line + "\n", expectedToken: "tok-abc")
        #expect(events.count == 1)
        guard case let .attached(created, _, _) = events[0].kind else {
            Issue.record("Expected .attached")
            return
        }
        #expect(created == false)
    }

    // MARK: - Required incarnation fields on `attached` (M2)

    @Test("attached line missing daemon_pid is dropped, not synthesized as (0,0)")
    func attachedMissingDaemonPidDropped() {
        // Synthesizing daemon_pid=0 would make two such lines compare equal as an
        // incarnation → a false reconnect that never clears stale agent chrome.
        let missingPid = """
        {"event":"attached","token":"tok-abc","created":true,"daemon_created_at":1700000000,"session":"ses-1","ts":1700000001}
        """
        let buffer = missingPid + "\n" + attachedLine + "\n"
        let events = AmxStatusEvent.parseLines(buffer, expectedToken: "tok-abc")
        // Only the well-formed line survives.
        #expect(events.count == 1)
        guard case let .attached(_, daemonPid, _) = events[0].kind else {
            Issue.record("Expected the surviving event to be .attached")
            return
        }
        #expect(daemonPid == 1234)
    }

    @Test("attached line missing daemon_created_at is dropped")
    func attachedMissingDaemonCreatedAtDropped() {
        let missingCreatedAt = """
        {"event":"attached","token":"tok-abc","created":true,"daemon_pid":4242,"session":"ses-1","ts":1700000001}
        """
        let events = AmxStatusEvent.parseLines(missingCreatedAt + "\n", expectedToken: "tok-abc")
        #expect(events.isEmpty)
    }

    @Test("a well-formed attached line still parses with its real incarnation")
    func wellFormedAttachedStillParses() {
        let events = AmxStatusEvent.parseLines(attachedLine + "\n", expectedToken: "tok-abc")
        #expect(events.count == 1)
        guard case let .attached(created, daemonPid, daemonCreatedAt) = events[0].kind else {
            Issue.record("Expected .attached")
            return
        }
        #expect(created == true)
        #expect(daemonPid == 1234)
        #expect(daemonCreatedAt == 1700000000)
    }

    // MARK: - Unknown event types

    @Test("unknown event type is dropped, not synthesized as session-end")
    func unknownEventTypeDropped() {
        let unknownEventLine = """
        {"event":"reattached","token":"tok-abc","session":"ses-1","ts":1700000005}
        """
        let validAttachedLine = """
        {"event":"attached","token":"tok-abc","created":true,"daemon_pid":1234,"daemon_created_at":1700000000,"session":"ses-1","ts":1700000001}
        """
        let buffer = unknownEventLine + "\n" + validAttachedLine + "\n"
        let events = AmxStatusEvent.parseLines(buffer, expectedToken: "tok-abc")

        // Should have only 1 event (the unknown one is dropped, attached remains)
        #expect(events.count == 1)
        // Verify it's the attached event, not a spurious session-end
        guard case .attached = events[0].kind else {
            Issue.record("Expected .attached as the only event; unknown event type should be dropped")
            return
        }
    }
}
