import Foundation
import Testing
@testable import AwesoMuxBridgeProtocol

@Suite
struct BridgeEnvelopeTests {

    // MARK: - Round trips

    @Test
    func agentStatusRoundTrips() throws {
        let envelope = BridgeEnvelope(
            token: "tok", session: "sess", id: "id1", ts: 1_700_000_000.5,
            message: .agentStatus(
                AgentStatus(
                    source: .claudeCode,
                    kind: .claudeCode,
                    execution: .thinking,
                    attentionReason: nil,
                    phase: .toolStart,
                    providerSessionID: "provider-1",
                    eventID: "abc123"
                )
            )
        )

        let line = try envelope.encodedLine()
        let decoded = BridgeEnvelope.parse(line: line)

        #expect(decoded == envelope)
    }

    @Test
    func paneRenameRoundTrips() throws {
        let envelope = BridgeEnvelope(
            token: "tok", session: "sess", id: "id2", ts: 1_700_000_001,
            message: .paneRename(title: "My Backend")
        )

        let decoded = BridgeEnvelope.parse(line: try envelope.encodedLine())
        #expect(decoded == envelope)
    }

    @Test
    func paneRenameEmptyTitleRoundTripsAsReset() throws {
        let envelope = BridgeEnvelope(
            token: "tok", session: "sess", id: "id2b", ts: 1_700_000_001,
            message: .paneRename(title: "")
        )

        let decoded = BridgeEnvelope.parse(line: try envelope.encodedLine())
        #expect(decoded == envelope)
        if case .paneRename(let title) = decoded?.message {
            #expect(title == "")
        } else {
            Issue.record("expected .paneRename")
        }
    }

    @Test
    func paneRenameAbsentTitleIsDropped() {
        let line = #"{"v":1,"type":"pane-rename","token":"tok","session":"sess","id":"id3","ts":1700000000}"#
        #expect(BridgeEnvelope.parse(line: line) == nil)
    }

    @Test
    func handoffNotifyRoundTrips() throws {
        let envelope = BridgeEnvelope(
            token: "tok", session: "sess", id: "id4", ts: 1_700_000_002,
            message: .handoffNotify(
                HandoffNotify(path: "/home/user/.awesomux-inbox/9f2c-clip.png", name: "clip.png", mediaKind: .image, bytes: 20480)
            )
        )

        let decoded = BridgeEnvelope.parse(line: try envelope.encodedLine())
        #expect(decoded == envelope)
    }

    @Test
    func permissionRequestRoundTrips() throws {
        let envelope = BridgeEnvelope(
            token: "tok", session: "sess", id: "req-4a1f", ts: 1_700_000_003,
            message: .permissionRequest(
                PermissionRequest(tool: "Bash", target: "rm -rf ./build", summary: "Delete build directory", expiresAt: 1_700_000_123)
            )
        )

        let decoded = BridgeEnvelope.parse(line: try envelope.encodedLine())
        #expect(decoded == envelope)
    }

    @Test
    func permissionRequestWithoutSummaryRoundTrips() throws {
        let envelope = BridgeEnvelope(
            token: "tok", session: "sess", id: "req-2", ts: 1_700_000_003,
            message: .permissionRequest(PermissionRequest(tool: "Read", target: "/etc/passwd", expiresAt: 1_700_000_200))
        )

        let decoded = BridgeEnvelope.parse(line: try envelope.encodedLine())
        #expect(decoded == envelope)
    }

    @Test
    func permissionDecisionRoundTrips() throws {
        let envelope = BridgeEnvelope(
            token: "tok", session: "sess", id: "dec-88c2", ts: 1_700_000_004,
            message: .permissionDecision(
                PermissionDecision(inReplyTo: "req-4a1f", decision: .deny, scope: .once, target: "rm -rf ./build")
            )
        )

        let decoded = BridgeEnvelope.parse(line: try envelope.encodedLine())
        #expect(decoded == envelope)
    }

    @Test
    func permissionResolvedRoundTrips() throws {
        let envelope = BridgeEnvelope(
            token: "tok", session: "sess", id: "id5", ts: 1_700_000_005,
            message: .permissionResolved(PermissionResolved(inReplyTo: "req-4a1f", reason: .expired))
        )

        let decoded = BridgeEnvelope.parse(line: try envelope.encodedLine())
        #expect(decoded == envelope)
    }

    @Test(arguments: [
        PermissionResolved.Reason.expired,
        .agentCancelled,
        .connectionLost,
        .overflow
    ])
    func permissionResolvedReasonVocabularyRoundTrips(reason: PermissionResolved.Reason) throws {
        let envelope = BridgeEnvelope(
            token: "tok", session: "sess", id: "id6", ts: 1_700_000_006,
            message: .permissionResolved(PermissionResolved(inReplyTo: "req-1", reason: reason))
        )

        let decoded = BridgeEnvelope.parse(line: try envelope.encodedLine())
        #expect(decoded == envelope)
    }

    // MARK: - encodedLine() self-validates

    /// The payload structs have plain public initializers with no
    /// validation of their own, so app code CAN construct an envelope that
    /// wouldn't survive `parse`. `encodedLine()` must catch that at encode
    /// time rather than silently emitting a line its own parser would drop
    /// (a real gap an adversarial review pass caught: constructing a
    /// hostile value directly and encoding it used to succeed).
    @Test
    func encodedLineThrowsForAHostileTitleBuiltDirectly() {
        let envelope = BridgeEnvelope(
            token: "tok", session: "sess", id: "id", ts: 1_700_000_000,
            message: .paneRename(title: "evil\u{202E}title")
        )

        #expect(throws: (any Error).self) {
            try envelope.encodedLine()
        }
    }

    @Test
    func encodedLineThrowsForAnOverCapFrame() {
        let envelope = BridgeEnvelope(
            token: "tok", session: "sess", id: "id", ts: 1_700_000_000,
            message: .paneRename(title: String(repeating: "x", count: 4 * 1024))
        )

        #expect(throws: (any Error).self) {
            try envelope.encodedLine()
        }
    }

    // MARK: - Unknown type / version

    @Test
    func unknownTypeIsDropped() {
        let line = #"{"v":1,"type":"agent-teleport","token":"tok","session":"sess","id":"id7","ts":1700000000}"#
        #expect(BridgeEnvelope.parse(line: line) == nil)
    }

    @Test
    func unknownVersionIsDropped() {
        let line = #"{"v":2,"type":"pane-rename","token":"tok","session":"sess","id":"id8","ts":1700000000,"title":"x"}"#
        #expect(BridgeEnvelope.parse(line: line) == nil)
    }

    @Test
    func malformedJSONIsDropped() {
        #expect(BridgeEnvelope.parse(line: #"{"v":1,"type":"pane-rename""#) == nil)
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
        return #"{"v":1,"type":"\#(type)","token":"tok","session":"sess","id":"id","ts":1700000000,\#(requiredFields),"pad":"\#(String(repeating: "x", count: padLength))"}"#
    }

    private static let fourKiBTypes: [(type: String, fields: String)] = [
        ("agent-status", #""source":"claude-code""#),
        ("pane-rename", #""title":"hi""#),
        ("permission-resolved", #""inReplyTo":"req-1","reason":"expired""#)
    ]

    private static let eightKiBTypes: [(type: String, fields: String)] = [
        ("handoff-notify", #""path":"/tmp/f","mediaKind":"file""#),
        ("permission-request", #""tool":"Bash","target":"ls","expiresAt":1700000200"#),
        ("permission-decision", #""inReplyTo":"req-1","decision":"allow","scope":"once","target":"ls""#)
    ]

    @Test(arguments: fourKiBTypes)
    func fourKiBCapBoundaryPasses(entry: (type: String, fields: String)) {
        let line = paddedLine(type: entry.type, requiredFields: entry.fields, totalBytes: 4 * 1024)
        #expect(line.utf8.count == 4 * 1024)
        #expect(BridgeEnvelope.parse(line: line) != nil)
    }

    @Test(arguments: fourKiBTypes)
    func fourKiBCapOneOverFails(entry: (type: String, fields: String)) {
        let line = paddedLine(type: entry.type, requiredFields: entry.fields, totalBytes: 4 * 1024 + 1)
        #expect(BridgeEnvelope.parse(line: line) == nil)
    }

    @Test(arguments: eightKiBTypes)
    func eightKiBCapBoundaryPasses(entry: (type: String, fields: String)) {
        let line = paddedLine(type: entry.type, requiredFields: entry.fields, totalBytes: 8 * 1024)
        #expect(line.utf8.count == 8 * 1024)
        #expect(BridgeEnvelope.parse(line: line) != nil)
    }

    @Test(arguments: eightKiBTypes)
    func eightKiBCapOneOverFails(entry: (type: String, fields: String)) {
        let line = paddedLine(type: entry.type, requiredFields: entry.fields, totalBytes: 8 * 1024 + 1)
        #expect(BridgeEnvelope.parse(line: line) == nil)
    }

    // MARK: - Scalar-safety rejection of hostile free-text fields

    private static let bidiOverride = "\u{202E}"
    private static let zeroWidthSpace = "\u{200B}"

    @Test(arguments: [bidiOverride, zeroWidthSpace])
    func hostileTitleIsRejected(hazard: String) {
        let line = #"{"v":1,"type":"pane-rename","token":"tok","session":"sess","id":"id","ts":1700000000,"title":"evil\#(hazard)title"}"#
        #expect(BridgeEnvelope.parse(line: line) == nil)
    }

    @Test(arguments: [bidiOverride, zeroWidthSpace])
    func hostilePathIsRejected(hazard: String) {
        let line = #"{"v":1,"type":"handoff-notify","token":"tok","session":"sess","id":"id","ts":1700000000,"path":"/tmp/evil\#(hazard)path","mediaKind":"file"}"#
        #expect(BridgeEnvelope.parse(line: line) == nil)
    }

    /// `name` is advisory display text next to the path — the same
    /// RLO-filename-spoofing class `path` is guarded against, so it gets
    /// the identical fence (present-but-hostile drops the whole frame).
    @Test(arguments: [bidiOverride, zeroWidthSpace])
    func hostileNameIsRejected(hazard: String) {
        let line = #"{"v":1,"type":"handoff-notify","token":"tok","session":"sess","id":"id","ts":1700000000,"path":"/tmp/f","name":"evil\#(hazard)name","mediaKind":"file"}"#
        #expect(BridgeEnvelope.parse(line: line) == nil)
    }

    @Test(arguments: [bidiOverride, zeroWidthSpace])
    func hostileToolIsRejected(hazard: String) {
        let line = #"{"v":1,"type":"permission-request","token":"tok","session":"sess","id":"id","ts":1700000000,"tool":"Ba\#(hazard)sh","target":"ls","expiresAt":1700000200}"#
        #expect(BridgeEnvelope.parse(line: line) == nil)
    }

    @Test(arguments: [bidiOverride, zeroWidthSpace])
    func hostileSummaryIsRejected(hazard: String) {
        let line = #"{"v":1,"type":"permission-request","token":"tok","session":"sess","id":"id","ts":1700000000,"tool":"Bash","target":"ls","summary":"de\#(hazard)lete","expiresAt":1700000200}"#
        #expect(BridgeEnvelope.parse(line: line) == nil)
    }

    @Test(arguments: [bidiOverride, zeroWidthSpace])
    func hostileTargetIsRejectedInPermissionRequest(hazard: String) {
        let line = #"{"v":1,"type":"permission-request","token":"tok","session":"sess","id":"id","ts":1700000000,"tool":"Bash","target":"rm \#(hazard)-rf","expiresAt":1700000200}"#
        #expect(BridgeEnvelope.parse(line: line) == nil)
    }

    @Test(arguments: [bidiOverride, zeroWidthSpace])
    func hostileTargetIsRejectedInPermissionDecision(hazard: String) {
        let line = #"{"v":1,"type":"permission-decision","token":"tok","session":"sess","id":"id","ts":1700000000,"inReplyTo":"req-1","decision":"allow","scope":"once","target":"rm \#(hazard)-rf"}"#
        #expect(BridgeEnvelope.parse(line: line) == nil)
    }

    @Test
    func nonAbsolutePathIsRejected() {
        let line = #"{"v":1,"type":"handoff-notify","token":"tok","session":"sess","id":"id","ts":1700000000,"path":"relative/path.png","mediaKind":"image"}"#
        #expect(BridgeEnvelope.parse(line: line) == nil)
    }

    // MARK: - source vocabulary

    @Test
    func unknownAgentStatusSourceParsesAsUnknown() {
        let line = #"{"v":1,"type":"agent-status","token":"tok","session":"sess","id":"id","ts":1700000000,"source":"gemini"}"#
        let decoded = BridgeEnvelope.parse(line: line)
        if case .agentStatus(let payload) = decoded?.message {
            #expect(payload.source == .unknown)
        } else {
            Issue.record("expected .agentStatus")
        }
    }

    @Test(arguments: [
        ("claude-code", AgentRuntimeSource.claudeCode),
        ("codex", .codex),
        ("opencode", .openCode),
        ("pi", .pi),
        ("grok", .grok)
    ])
    func knownAgentStatusSourcesParse(raw: String, expected: AgentRuntimeSource) {
        let line = #"{"v":1,"type":"agent-status","token":"tok","session":"sess","id":"id","ts":1700000000,"source":"\#(raw)"}"#
        let decoded = BridgeEnvelope.parse(line: line)
        if case .agentStatus(let payload) = decoded?.message {
            #expect(payload.source == expected)
        } else {
            Issue.record("expected .agentStatus")
        }
    }

    @Test
    func agentStatusMissingSourceIsDropped() {
        let line = #"{"v":1,"type":"agent-status","token":"tok","session":"sess","id":"id","ts":1700000000}"#
        #expect(BridgeEnvelope.parse(line: line) == nil)
    }
}
