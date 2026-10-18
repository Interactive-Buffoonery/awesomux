import Foundation
import Testing
@testable import AwesoMuxBridgeProtocol

@Suite
struct BridgeEnvelopeTests {
    @Test(arguments: [
        #"{"v":1,"type":"pane-rename","token":"tok","session":"sess","id":"id3","ts":1700000000}"#,
        #"{"v":1,"type":"agent-status","token":"tok","session":"sess","id":"id","ts":1700000000}"#,
        #"{"v":1,"type":"handoff-notify","token":"tok","session":"sess","id":"id","ts":1700000000,"path":"relative/path.png","mediaKind":"image"}"#,
        #"{"v":1,"type":"agent-teleport","token":"tok","session":"sess","id":"id7","ts":1700000000}"#,
        #"{"v":2,"type":"pane-rename","token":"tok","session":"sess","id":"id8","ts":1700000000,"title":"x"}"#,
        #"{"v":1,"type":"pane-rename""#,
    ])
    func invalidEnvelopeIsDropped(line: String) {
        #expect(BridgeEnvelope.parse(line: line) == nil)
    }

    @Test
    func helloMissingRequiredFieldIsDropped() {
        // Missing "helper".
        let line = #"{"type":"hello","proto":"awesomux-bridge-v1","token":"tok","session":"s","ts":1700000000}"#
        #expect(BridgeHandshake.parse(line: line) == nil)
    }

    // MARK: - encodedLine() self-validates

    /// The payload structs have plain public initializers with no
    /// validation of their own, so app code CAN construct an envelope that
    /// wouldn't survive `parse`. `encodedLine()` must catch that at encode
    /// time rather than silently emitting a line its own parser would drop
    /// (a real gap an adversarial review pass caught: constructing a
    /// hostile value directly and encoding it used to succeed).
    @Test(arguments: ["evil\u{202E}title", String(repeating: "x", count: 4 * 1024)])
    func encodedLineThrowsForAHostileTitleBuiltDirectly(title: String) {
        let envelope = BridgeEnvelope(
            token: "tok", session: "sess", id: "id", ts: 1_700_000_000,
            message: .paneRename(title: title)
        )

        #expect(throws: (any Error).self) {
            try envelope.encodedLine()
        }
    }

    // MARK: - Provider session id

    /// A remote host is an input to `providerSessionID`, and downstream the
    /// value becomes a filename component and staged terminal text. A hostile
    /// one is stripped, but the frame's status transition still applies —
    /// otherwise a bad id would be a way to suppress the transition entirely.
    @Test(arguments: ["evil\\nrm -rf ~", "../../../tmp/evil", "not-a-uuid"])
    func hostileProviderSessionIDIsStrippedFromAgentStatus(rawSessionID: String) throws {
        let line =
            #"{"v":1,"type":"agent-status","token":"tok","session":"sess","id":"id9","ts":1700000000,"source":"claude-code","execution":"thinking","providerSessionID":"\#(rawSessionID)"}"#

        let decoded = try #require(BridgeEnvelope.parse(line: line))
        guard case .agentStatus(let status) = decoded.message else {
            Issue.record("expected .agentStatus")
            return
        }
        #expect(status.providerSessionID == nil)
        #expect(status.execution == .thinking)
    }

    /// Same rule one layer earlier: a WRONG-TYPED id (a helper that emits a
    /// number, or an array) must cost the field, not the frame. A strict
    /// `String?` threw out of the whole `Wire` decode, so a remote host could
    /// suppress a lifecycle transition just by mistyping one value — while the
    /// local event-file path (`AgentRuntimeEvent.Payload`) let it through.
    @Test(arguments: ["42", "[\"a\"]", "{\"id\":\"a\"}", "true", "null"])
    func wrongTypedProviderSessionIDStripsTheFieldNotTheFrame(rawSessionID: String) throws {
        let line =
            #"{"v":1,"type":"agent-status","token":"tok","session":"sess","id":"id9b","ts":1700000000,"source":"claude-code","execution":"thinking","phase":"stop","providerSessionID":\#(rawSessionID)}"#

        let decoded = try #require(BridgeEnvelope.parse(line: line))
        guard case .agentStatus(let status) = decoded.message else {
            Issue.record("expected .agentStatus")
            return
        }
        #expect(status.providerSessionID == nil)
        #expect(status.execution == .thinking)
        #expect(status.phase == .stop)
    }

    // MARK: - Per-type size caps (raw line bytes, before full decode)

    /// Builds a syntactically valid line for `type` with the minimum
    /// required fields for that type, plus an unvalidated filler key
    /// (`pad`, which `Wire` never decodes) sized so the *total* line is
    /// exactly `totalBytes`. Padding through an ignored key — rather than a
    /// real field like `title` — lets the boundary sit exactly on the
    /// per-type byte cap without also tripping that field's own (much
    /// smaller) length cap.
    private func paddedLine(type: String, requiredFields: String, totalBytes: Int) -> String {
        let unpadded = #"{"v":1,"type":"\#(type)","token":"tok","session":"sess","id":"id","ts":1700000000,\#(requiredFields),"pad":""}"#
        let unpaddedBytes = unpadded.utf8.count
        precondition(totalBytes >= unpaddedBytes, "totalBytes too small to fit \(type)'s required fields")
        let padLength = totalBytes - unpaddedBytes
        return
            #"{"v":1,"type":"\#(type)","token":"tok","session":"sess","id":"id","ts":1700000000,\#(requiredFields),"pad":"\#(String(repeating: "x", count: padLength))"}"#
    }

    private static let fourKiBTypes: [(type: String, fields: String)] = [
        ("agent-status", #""source":"claude-code""#),
        ("pane-rename", #""title":"hi""#),
        ("permission-resolved", #""inReplyTo":"req-1","reason":"expired""#),
    ]

    private static let eightKiBTypes: [(type: String, fields: String)] = [
        ("handoff-notify", #""path":"/tmp/f","mediaKind":"file""#),
        ("permission-request", #""tool":"Bash","target":"ls","expiresAt":1700000200"#),
        ("permission-decision", #""inReplyTo":"req-1","decision":"allow","scope":"once","target":"ls""#),
    ]

    @Test(
        arguments: fourKiBTypes.map { ($0.type, $0.fields, 4 * 1024) }
            + eightKiBTypes.map { ($0.type, $0.fields, 8 * 1024) })
    func frameByteCap(entry: (type: String, fields: String, cap: Int)) {
        let line = paddedLine(type: entry.type, requiredFields: entry.fields, totalBytes: entry.cap)
        #expect(line.utf8.count == entry.cap)
        #expect(BridgeEnvelope.parse(line: line) != nil)
        #expect(BridgeEnvelope.parse(line: line + " ") == nil)
    }

    // MARK: - Scalar-safety rejection of hostile free-text fields

    private static let bidiOverride = "\u{202E}"
    private static let zeroWidthSpace = "\u{200B}"

    @Test(arguments: [bidiOverride, zeroWidthSpace])
    func hostileFreeTextIsRejected(hazard: String) {
        let lines = [
            #"{"v":1,"type":"pane-rename","token":"tok","session":"sess","id":"id","ts":1700000000,"title":"evil\#(hazard)title"}"#,
            #"{"v":1,"type":"handoff-notify","token":"tok","session":"sess","id":"id","ts":1700000000,"path":"/tmp/evil\#(hazard)path","mediaKind":"file"}"#,
            #"{"v":1,"type":"handoff-notify","token":"tok","session":"sess","id":"id","ts":1700000000,"path":"/tmp/f","name":"evil\#(hazard)name","mediaKind":"file"}"#,
            #"{"v":1,"type":"permission-request","token":"tok","session":"sess","id":"id","ts":1700000000,"tool":"Ba\#(hazard)sh","target":"ls","expiresAt":1700000200}"#,
            #"{"v":1,"type":"permission-request","token":"tok","session":"sess","id":"id","ts":1700000000,"tool":"Bash","target":"ls","summary":"de\#(hazard)lete","expiresAt":1700000200}"#,
            #"{"v":1,"type":"permission-request","token":"tok","session":"sess","id":"id","ts":1700000000,"tool":"Bash","target":"rm \#(hazard)-rf","expiresAt":1700000200}"#,
            #"{"v":1,"type":"permission-decision","token":"tok","session":"sess","id":"id","ts":1700000000,"inReplyTo":"req-1","decision":"allow","scope":"once","target":"rm \#(hazard)-rf"}"#,
        ]
        for line in lines {
            #expect(BridgeEnvelope.parse(line: line) == nil)
        }
    }

    // MARK: - source vocabulary

}
