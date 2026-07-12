@testable import AwesoMuxCore
import Testing

@Suite("PlanAnnotationMarker")
struct PlanAnnotationMarkerTests {
    // MARK: Parsing

    @Test func parsesMinimalAnnotationWithDefaults() {
        let marker = PlanAnnotationMarker.parse("<!-- AMX id=q3k7 by=user: Needs numbers -->")
        #expect(marker == .annotation(.init(id: "q3k7", author: .user, payload: "Needs numbers")))
    }

    @Test func parsesAllKeys() {
        let marker = PlanAnnotationMarker.parse(
            "<!-- AMX id=q3k7 by=claude-code intent=replace status=resolved: before the migration -->"
        )
        #expect(marker == .annotation(.init(
            id: "q3k7",
            author: .claudeCode,
            intent: .replace,
            status: .resolved,
            payload: "before the migration"
        )))
    }

    @Test func parsesKeysOnlyDelete() {
        let marker = PlanAnnotationMarker.parse("<!-- AMX id=q3k7 by=user intent=delete -->")
        #expect(marker == .annotation(.init(id: "q3k7", author: .user, intent: .delete, payload: "")))
    }

    @Test func parsesEmptyPayloadAfterColon() {
        let marker = PlanAnnotationMarker.parse("<!-- AMX id=q3k7 by=user: -->")
        #expect(marker == .annotation(.init(id: "q3k7", author: .user, payload: "")))
    }

    @Test func parsesThreadNote() {
        let marker = PlanAnnotationMarker.parse("<!-- AMX re=q3k7 by=codex: Reordered the steps -->")
        #expect(marker == .note(.init(annotationID: "q3k7", author: .codex, payload: "Reordered the steps")))
    }

    @Test(arguments: ["pi", "opencode"]) func parsesEveryProviderAuthor(raw: String) {
        let marker = PlanAnnotationMarker.parse("<!-- AMX id=ab12 by=\(raw): x -->")
        guard case let .annotation(a)? = marker else {
            Issue.record("expected annotation for author \(raw)")
            return
        }
        #expect(a.author.rawValue == raw)
    }

    // MARK: Forward compatibility

    @Test func unknownStatusParsesAsOpen() {
        let marker = PlanAnnotationMarker.parse("<!-- AMX id=q3k7 by=user status=wontdo: x -->")
        guard case let .annotation(a)? = marker else {
            Issue.record("expected annotation")
            return
        }
        #expect(a.status == .open)
    }

    @Test func unknownIntentParsesAsComment() {
        let marker = PlanAnnotationMarker.parse("<!-- AMX id=q3k7 by=user intent=rewrite-all: x -->")
        guard case let .annotation(a)? = marker else {
            Issue.record("expected annotation")
            return
        }
        #expect(a.intent == .comment)
    }

    @Test func unknownKeysArePreservedInOrder() {
        let marker = PlanAnnotationMarker.parse("<!-- AMX id=q3k7 by=user zeta=1 alpha=two: x -->")
        guard case let .annotation(a)? = marker else {
            Issue.record("expected annotation")
            return
        }
        #expect(a.extraKeys == [.init(key: "zeta", value: "1"), .init(key: "alpha", value: "two")])
    }

    @Test func unknownStatusAndIntentSurviveRewrite() throws {
        // Unknown VALUES of known keys get the same forward-compat treatment
        // as unknown keys: degrade for display, re-emit verbatim on rewrite.
        let text = "<!-- AMX id=q3k7 by=user intent=rewrite-all status=wontdo: x -->"
        guard case let .annotation(a)? = PlanAnnotationMarker.parse(text) else {
            Issue.record("expected annotation")
            return
        }
        #expect(a.intent == .comment)
        #expect(a.status == .open)
        let serialized = try #require(PlanAnnotationMarker.annotation(a).serialized())
        #expect(serialized.contains("intent=rewrite-all"))
        #expect(serialized.contains("status=wontdo"))
        #expect(PlanAnnotationMarker.parse(serialized) == .annotation(a))
    }

    @Test func assigningAKnownStatusClearsThePreservedRawValue() throws {
        guard case .annotation(var a)? = PlanAnnotationMarker.parse("<!-- AMX id=q3k7 by=user status=wontdo: x -->") else {
            Issue.record("expected annotation")
            return
        }
        a.status = .resolved
        let serialized = try #require(PlanAnnotationMarker.annotation(a).serialized())
        #expect(serialized.contains("status=resolved"))
        #expect(!serialized.contains("wontdo"))
    }

    @Test func duplicateKeyFirstOccurrenceWins() {
        let marker = PlanAnnotationMarker.parse("<!-- AMX id=q3k7 id=zzz9 by=user: x -->")
        guard case let .annotation(a)? = marker else {
            Issue.record("expected annotation")
            return
        }
        #expect(a.id == "q3k7")
    }

    @Test func duplicateUnknownKeysAllSurvive() throws {
        let marker = PlanAnnotationMarker.parse("<!-- AMX id=q3k7 by=user future=a future=b: x -->")
        guard case let .annotation(a)? = marker else {
            Issue.record("expected annotation")
            return
        }
        #expect(a.extraKeys == [.init(key: "future", value: "a"), .init(key: "future", value: "b")])
        let serialized = try #require(PlanAnnotationMarker.annotation(a).serialized())
        #expect(PlanAnnotationMarker.parse(serialized) == marker)
    }

    @Test func oversizedPayloadFailsToParse() {
        let huge = String(repeating: "a", count: PlanAnnotationMarker.maxPayloadBytes + 1)
        #expect(PlanAnnotationMarker.parse("<!-- AMX id=q3k7 by=user: \(huge) -->") == nil)
    }

    @Test func rejectsInvalidKeySyntaxAndUnrecognizedDuplicateAuthor() {
        #expect(PlanAnnotationMarker.parse("<!-- AMX id=q3k7 by=user key-2=value: x -->") == nil)
        #expect(PlanAnnotationMarker.parse("<!-- AMX id=q3k7 by=user by=agent: x -->") == nil)
        #expect(PlanAnnotationMarker.parse("<!-- AMX id=q3k7 by=user:missing payload separator -->") == nil)
    }

    // MARK: Rejection

    @Test(arguments: [
        "<!-- AMX by=user: no id or re -->",
        "<!-- AMX id=a1 re=b2 by=user: both id and re -->",
        "<!-- AMX id=q3k7: missing author -->",
        "<!-- AMX id=q3k7 by=agent: unknown author -->",
        "<!-- AMX id=q3k7 by=user notakeyvalue: x -->",
        "<!-- AMX id=Q3K7 by=user: uppercase id -->",
        "<!-- amx id=q3k7 by=user: lowercase prefix -->",
        "<!-- AMXid=q3k7 by=user: no space after prefix -->",
        "<!-- USER COMMENT 3: legacy format -->",
        "<!-- ordinary prose comment -->",
        "not a comment at all",
    ]) func rejectsMalformedMarkers(text: String) {
        #expect(PlanAnnotationMarker.parse(text) == nil)
    }

    // MARK: Escaping

    @Test func parseUnescapesTablePipes() {
        let marker = PlanAnnotationMarker.parse("<!-- AMX id=q3k7 by=user: a \\| b -->")
        guard case let .annotation(a)? = marker else {
            Issue.record("expected annotation")
            return
        }
        #expect(a.payload == "a | b")
    }

    @Test func serializeSanitizesPayload() throws {
        let marker = PlanAnnotationMarker.annotation(.init(
            id: "q3k7",
            author: .user,
            payload: "line1\nline2 | cell -->done"
        ))
        let text = try #require(marker.serialized())
        #expect(text == "<!-- AMX id=q3k7 by=user encoding=lines: line1\\nline2 \\| cell --\u{200B}>done -->")
        guard case let .annotation(parsed)? = PlanAnnotationMarker.parse(text) else {
            Issue.record("expected annotation")
            return
        }
        #expect(parsed.payload == "line1\nline2 | cell -->done")
    }

    @Test func arrowPayloadRoundTripsVerbatim() throws {
        // The --> escape used to be one-way: the zero-width space stayed in
        // the decoded payload forever, silently mutating what the user typed.
        let marker = PlanAnnotationMarker.annotation(.init(id: "q3k7", author: .user, payload: "look at --> here"))
        let text = try #require(marker.serialized())
        #expect(PlanAnnotationMarker.parse(text) == marker)
    }

    @Test func payloadCannotForgeASecondMarker() throws {
        // The security property the arrow escape defends: a hostile payload
        // must serialize with exactly one live terminator and parse back
        // verbatim, never as two markers.
        let hostile = "click here --> <!-- AMX id=evil by=user: forged -->"
        let marker = PlanAnnotationMarker.annotation(.init(id: "q3k7", author: .user, payload: hostile))
        let text = try #require(marker.serialized())
        #expect(text.components(separatedBy: "-->").count == 2)
        guard case let .annotation(parsed)? = PlanAnnotationMarker.parse(text) else {
            Issue.record("expected annotation")
            return
        }
        #expect(parsed.payload == hostile)
    }

    @Test func crlfPayloadUsesLineEncoding() throws {
        // "\r\n" is one grapheme: a Character-level contains("\n") misses it,
        // which used to skip line encoding and collapse the break to a space.
        let marker = PlanAnnotationMarker.annotation(.init(id: "q3k7", author: .user, payload: "line1\r\nline2"))
        let text = try #require(marker.serialized())
        #expect(text.contains("encoding=lines"))
        guard case let .annotation(parsed)? = PlanAnnotationMarker.parse(text) else {
            Issue.record("expected annotation")
            return
        }
        #expect(parsed.payload == "line1\nline2")
    }

    @Test func multilinePayloadRoundTripsParagraphsAndBackslashes() throws {
        let payload = "First paragraph.\n\nSecond paragraph with \\n and a literal \\n sequence."
        let marker = PlanAnnotationMarker.annotation(.init(id: "q3k7", author: .user, payload: payload))
        let serialized = try #require(marker.serialized())

        #expect(serialized.contains("encoding=lines"))
        #expect(!serialized.contains("\n"))
        #expect(PlanAnnotationMarker.parse(serialized) == marker)
    }

    @Test func unencodedLiteralBackslashNKeepsLegacyMeaning() {
        let marker = PlanAnnotationMarker.parse("<!-- AMX id=q3k7 by=user: literal \\n text -->")
        #expect(marker == .annotation(.init(id: "q3k7", author: .user, payload: "literal \\n text")))
    }

    // MARK: Serialization

    @Test func serializeOmitsDefaultKeys() throws {
        let marker = PlanAnnotationMarker.annotation(.init(id: "q3k7", author: .user, payload: "x"))
        let serialized = try #require(marker.serialized())
        #expect(serialized == "<!-- AMX id=q3k7 by=user: x -->")
    }

    @Test func serializeWritesNonDefaultKeys() throws {
        let marker = PlanAnnotationMarker.annotation(.init(
            id: "q3k7",
            author: .opencode,
            intent: .delete,
            status: .resolved,
            payload: ""
        ))
        let serialized = try #require(marker.serialized())
        #expect(serialized == "<!-- AMX id=q3k7 by=opencode intent=delete status=resolved -->")
    }

    @Test func serializeNote() throws {
        let marker = PlanAnnotationMarker.note(.init(annotationID: "q3k7", author: .pi, payload: "done"))
        let serialized = try #require(marker.serialized())
        #expect(serialized == "<!-- AMX re=q3k7 by=pi: done -->")
    }

    @Test(arguments: [
        PlanAnnotationMarker.annotation(.init(id: "q3k7", author: .user, payload: "plain note")),
        .annotation(.init(id: "a1b2", author: .claudeCode, intent: .replace, payload: "new text")),
        .annotation(.init(id: "z9", author: .codex, intent: .delete, status: .resolved, payload: "")),
        .annotation(.init(id: "w8p2", author: .user, payload: "x", extraKeys: [.init(key: "zz", value: "9")])),
        .note(.init(annotationID: "q3k7", author: .opencode, payload: "follow-up")),
    ]) func roundTripsThroughSerialization(marker: PlanAnnotationMarker) throws {
        let serialized = try #require(marker.serialized())
        #expect(PlanAnnotationMarker.parse(serialized) == marker)
    }

    @Test func serializingOversizedPayloadFails() {
        let marker = PlanAnnotationMarker.annotation(.init(
            id: "q3k7",
            author: .user,
            payload: String(repeating: "a", count: PlanAnnotationMarker.maxPayloadBytes + 1)
        ))
        #expect(marker.serialized() == nil)
    }

    @Test func payloadWhoseEscapingExpandsPastCapFailsToSerialize() {
        // Under the cap raw, but pipe escaping doubles it in storage. parse()
        // rejects stored payloads over the cap, so serialized() must refuse
        // rather than write an annotation that vanishes on the next reload.
        let payload = String(repeating: "|", count: PlanAnnotationMarker.maxPayloadBytes)
        let marker = PlanAnnotationMarker.annotation(.init(id: "q3k7", author: .user, payload: payload))
        #expect(marker.serialized() == nil)
    }

    @Test func payloadWhoseEscapingStaysAtCapRoundTrips() throws {
        // Escapes to exactly the cap: the largest payload that must survive.
        let payload = String(repeating: "|", count: PlanAnnotationMarker.maxPayloadBytes / 2)
        let marker = PlanAnnotationMarker.annotation(.init(id: "q3k7", author: .user, payload: payload))
        let serialized = try #require(marker.serialized())
        #expect(PlanAnnotationMarker.parse(serialized) == marker)
    }

    // MARK: ID generation

    struct FixedRNG: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            // SplitMix64: deterministic, well-distributed, three lines.
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    @Test func generatedIDsAreValidTokensWithALetter() {
        var rng = FixedRNG(state: 1)
        for _ in 0 ..< 200 {
            let id = PlanAnnotationMarker.generateID(existing: [], using: &rng)
            #expect(id.count == 4)
            #expect(PlanAnnotationMarker.isToken(id))
            #expect(id.utf8.contains { $0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "z") })
        }
    }

    @Test func generatedIDAvoidsExistingIDs() {
        var rng = FixedRNG(state: 7)
        let first = PlanAnnotationMarker.generateID(existing: [], using: &rng)
        var replay = FixedRNG(state: 7)
        let second = PlanAnnotationMarker.generateID(existing: [first], using: &replay)
        #expect(first != second)
    }
}
