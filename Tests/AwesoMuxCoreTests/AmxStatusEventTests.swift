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

    @Test("parses complete JSONL records and ignores an unfinished trailing record", arguments: [false, true])
    func parseTwoCompleteLines(trailingNewline: Bool) throws {
        let buffer = attachedLine + "\n" + sessionEndLine + (trailingNewline ? "\n" : "")
        let events = AmxStatusEvent.parseLines(buffer, expectedToken: "tok-abc")

        #expect(events.count == (trailingNewline ? 2 : 1))

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

        guard trailingNewline else { return }

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

    @Test(arguments: [
        "this is not json at all",
        """
        {"event":"attached","token":"tok-abc","created":true,"daemon_created_at":1700000000,"session":"ses-1","ts":1700000001}
        """,
        """
        {"event":"attached","token":"tok-abc","created":true,"daemon_pid":4242,"session":"ses-1","ts":1700000001}
        """,
        """
        {"event":"reattached","token":"tok-abc","session":"ses-1","ts":1700000005}
        """,
        """
        {"event":"attached","token":"tok-abc","created":true,"daemon_pid":0,"daemon_created_at":1700000000,"session":"ses-1","ts":1700000001}
        """,
        """
        {"event":"attached","token":"tok-abc","created":true,"daemon_pid":-1,"daemon_created_at":1700000000,"session":"ses-1","ts":1700000001}
        """,
        """
        {"event":"attached","token":"tok-abc","created":true,"daemon_pid":42,"daemon_created_at":0,"session":"ses-1","ts":1700000001}
        """,
        """
        {"event":"attached","token":"tok-abc","created":true,"daemon_pid":42,"daemon_created_at":-1,"session":"ses-1","ts":1700000001}
        """,
    ])
    func rejectedLines(line: String) {
        #expect(AmxStatusEvent.parseLines(line + "\n", expectedToken: "tok-abc").isEmpty)
        let events = AmxStatusEvent.parseLines(line + "\n" + attachedLine + "\n", expectedToken: "tok-abc")
        #expect(events.count == 1)
        #expect(events.first == AmxStatusEvent.parseLines(attachedLine + "\n", expectedToken: "tok-abc").first)
    }
}
