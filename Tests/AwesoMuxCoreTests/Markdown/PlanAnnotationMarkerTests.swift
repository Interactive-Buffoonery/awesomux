import Testing
@testable import AwesoMuxCore

@Suite("PlanAnnotationMarker")
struct PlanAnnotationMarkerTests {
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

    @Test(arguments: [
        (
            "<!-- AMX id=q3k7 by=user: Needs numbers -->",
            PlanAnnotationMarker.annotation(.init(id: "q3k7", author: .user, payload: "Needs numbers"))
        ),
        (
            "<!-- AMX id=q3k7 by=claude-code intent=replace status=resolved: before the migration -->",
            .annotation(.init(id: "q3k7", author: .claudeCode, intent: .replace, status: .resolved, payload: "before the migration"))
        ),
        ("<!-- AMX id=q3k7 by=user intent=delete -->", .annotation(.init(id: "q3k7", author: .user, intent: .delete, payload: ""))),
        ("<!-- AMX id=q3k7 by=user: -->", .annotation(.init(id: "q3k7", author: .user, payload: ""))),
        (
            "<!-- AMX re=q3k7 by=codex: Reordered the steps -->",
            .note(.init(annotationID: "q3k7", author: .codex, payload: "Reordered the steps"))
        ),
        ("<!-- AMX id=ab12 by=pi: x -->", .annotation(.init(id: "ab12", author: .pi, payload: "x"))),
        ("<!-- AMX id=ab12 by=opencode: x -->", .annotation(.init(id: "ab12", author: .opencode, payload: "x"))),
        ("<!-- AMX id=q3k7 by=user status=wontdo: x -->", .annotation(.init(id: "q3k7", author: .user, payload: "x", rawStatus: "wontdo"))),
        (
            "<!-- AMX id=q3k7 by=user intent=rewrite-all: x -->",
            .annotation(.init(id: "q3k7", author: .user, payload: "x", rawIntent: "rewrite-all"))
        ),
        ("<!-- AMX id=q3k7 id=zzz9 by=user: x -->", .annotation(.init(id: "q3k7", author: .user, payload: "x"))),
        ("<!-- AMX id=q3k7 by=user: a \\| b -->", .annotation(.init(id: "q3k7", author: .user, payload: "a | b"))),
        ("<!-- AMX id=q3k7 by=user: literal \\n text -->", .annotation(.init(id: "q3k7", author: .user, payload: "literal \\n text"))),
    ])
    func parsedMarkers(text: String, expected: PlanAnnotationMarker) {
        #expect(PlanAnnotationMarker.parse(text) == expected)
    }

    @Test(arguments: [
        "<!-- AMX by=user: no id or re -->", "<!-- AMX id=a1 re=b2 by=user: both id and re -->",
        "<!-- AMX id=q3k7: missing author -->", "<!-- AMX id=q3k7 by=agent: unknown author -->",
        "<!-- AMX id=q3k7 by=user notakeyvalue: x -->", "<!-- AMX id=Q3K7 by=user: uppercase id -->",
        "<!-- amx id=q3k7 by=user: lowercase prefix -->", "<!-- AMXid=q3k7 by=user: no space after prefix -->",
        "<!-- USER COMMENT 3: legacy format -->", "<!-- ordinary prose comment -->", "not a comment at all",
        "<!-- AMX id=q3k7 by=user key-2=value: x -->", "<!-- AMX id=q3k7 by=user by=agent: x -->",
        "<!-- AMX id=q3k7 by=user:missing payload separator -->",
        "<!-- AMX id=q3k7 by=user: \(String(repeating: "a", count: PlanAnnotationMarker.maxPayloadBytes + 1)) -->",
    ])
    func rejectedMarkers(text: String) { #expect(PlanAnnotationMarker.parse(text) == nil) }

    @Test(
        arguments: [
            (PlanAnnotationMarker.annotation(.init(id: "q3k7", author: .user, payload: "plain note")), nil, nil),
            (.annotation(.init(id: "q3k7", author: .user, payload: "x")), "<!-- AMX id=q3k7 by=user: x -->", nil),
            (
                .annotation(.init(id: "q3k7", author: .opencode, intent: .delete, status: .resolved, payload: "")),
                "<!-- AMX id=q3k7 by=opencode intent=delete status=resolved -->", nil
            ),
            (.note(.init(annotationID: "q3k7", author: .pi, payload: "done")), "<!-- AMX re=q3k7 by=pi: done -->", nil),
            (.annotation(.init(id: "a1b2", author: .claudeCode, intent: .replace, payload: "new text")), nil, nil),
            (.annotation(.init(id: "z9", author: .codex, intent: .delete, status: .resolved, payload: "")), nil, nil),
            (.annotation(.init(id: "w8p2", author: .user, payload: "x", extraKeys: [.init(key: "zz", value: "9")])), nil, nil),
            (.note(.init(annotationID: "q3k7", author: .opencode, payload: "follow-up")), nil, nil),
            (
                .annotation(
                    .init(
                        id: "q3k7", author: .user, payload: "x",
                        extraKeys: [.init(key: "zeta", value: "1"), .init(key: "alpha", value: "two")])),
                "<!-- AMX id=q3k7 by=user zeta=1 alpha=two: x -->", nil
            ),
            (
                .annotation(.init(id: "q3k7", author: .user, payload: "x", rawIntent: "rewrite-all", rawStatus: "wontdo")),
                "<!-- AMX id=q3k7 by=user intent=rewrite-all status=wontdo: x -->", nil
            ),
            (
                .annotation(
                    .init(
                        id: "q3k7", author: .user, payload: "x",
                        extraKeys: [.init(key: "future", value: "a"), .init(key: "future", value: "b")])),
                "<!-- AMX id=q3k7 by=user future=a future=b: x -->", nil
            ),
            (.annotation(.init(id: "q3k7", author: .user, payload: "look at --> here")), nil, nil),
            (
                .annotation(.init(id: "q3k7", author: .user, payload: "line1\r\nline2")),
                "<!-- AMX id=q3k7 by=user encoding=lines: line1\\nline2 -->",
                .annotation(.init(id: "q3k7", author: .user, payload: "line1\nline2"))
            ),
            (
                .annotation(
                    .init(id: "q3k7", author: .user, payload: "First paragraph.\n\nSecond paragraph with \\n and a literal \\n sequence.")),
                nil, nil
            ),
            (
                .annotation(.init(id: "q3k7", author: .user, payload: "line1\nline2 | cell -->done")),
                "<!-- AMX id=q3k7 by=user encoding=lines: line1\\nline2 \\| cell --\u{200B}>done -->", nil
            ),
        ] as [(PlanAnnotationMarker, String?, PlanAnnotationMarker?)])
    func markerRoundTrips(marker: PlanAnnotationMarker, exact: String?, normalized: PlanAnnotationMarker?) throws {
        if let exact {
            #expect(PlanAnnotationMarker.parse(exact) == (normalized ?? marker))
        }
        let serialized = try #require(marker.serialized())
        if let exact { #expect(serialized == exact) }
        #expect(!serialized.contains("\n"))
        #expect(PlanAnnotationMarker.parse(serialized) == (normalized ?? marker))
    }

    @Test(arguments: [
        (String(repeating: "a", count: PlanAnnotationMarker.maxPayloadBytes + 1), false),
        (String(repeating: "|", count: PlanAnnotationMarker.maxPayloadBytes), false),
        (String(repeating: "|", count: PlanAnnotationMarker.maxPayloadBytes / 2), true),
    ])
    func payloadCaps(payload: String, accepted: Bool) throws {
        let marker = PlanAnnotationMarker.annotation(.init(id: "q3k7", author: .user, payload: payload))
        if accepted {
            #expect(PlanAnnotationMarker.parse(try #require(marker.serialized())) == marker)
        } else {
            #expect(marker.serialized() == nil)
        }
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

    @Test func generatedIDAvoidsExistingIDs() {
        var rng = FixedRNG(state: 7)
        let first = PlanAnnotationMarker.generateID(existing: [], using: &rng)
        var replay = FixedRNG(state: 7)
        let second = PlanAnnotationMarker.generateID(existing: [first], using: &replay)
        #expect(first != second)
        #expect(first.count == 4)
        #expect(PlanAnnotationMarker.isToken(first))
        #expect(first.utf8.contains { $0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "z") })
    }
}
