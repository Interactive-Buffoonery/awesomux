import AwesoMuxBridgeProtocol
import AwesoMuxTestSupport
import Foundation
import SecureFileIO
import Testing

@testable import AwesoMuxCore

@Suite struct AgentTranscriptRendererTests {

    // MARK: - Helpers

    private static let sessionID = "11111111-2222-3333-4444-555555555555"

    private func render(
        _ lines: [String],
        provider: AgentTranscriptImporter.Provider = .claudeCode,
        agentKind: AgentKind = .claudeCode,
        hasEarlierBytes: Bool = false,
        isFinalWindow: Bool = true,
        budgetBytes: Int = AgentTranscriptRenderer.budgetBytes
    ) -> AgentTranscriptRenderer.Rendered {
        AgentTranscriptRenderer.render(
            jsonlTail: Data(lines.joined(separator: "\n").utf8),
            provider: provider,
            chrome: .unlocalizedFallback(agentKind: agentKind),
            sessionID: Self.sessionID,
            hasEarlierBytes: hasEarlierBytes,
            isFinalWindow: isFinalWindow,
            budgetBytes: budgetBytes
        )
    }

    private func renderCodex(
        _ lines: [String],
        budgetBytes: Int = AgentTranscriptRenderer.budgetBytes
    ) -> AgentTranscriptRenderer.Rendered {
        render(lines, provider: .codex, agentKind: .codex, budgetBytes: budgetBytes)
    }

    /// One JSONL line built through the encoder, so hostile fixture strings are
    /// escaped exactly the way a real transcript writer would escape them.
    private func jsonLine(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try #require(String(data: data, encoding: .utf8))
    }

    @Test("an oversized OpenCode part produces an explicit non-empty turn")
    func openCodeOversizedPartNeverReturnsEmpty() {
        let snapshot = OpenCodeTranscriptSnapshot(
            databaseURL: URL(fileURLWithPath: "/tmp/opencode.db"),
            messages: [
                .init(
                    id: "msg_1",
                    data: Data(#"{"role":"assistant"}"#.utf8),
                    parts: [.init(data: nil, byteCount: 2_000_000)]
                )
            ],
            isTruncated: false
        )

        let rendered = AgentTranscriptRenderer.renderOpenCode(
            snapshot,
            sessionID: "ses_01JABC",
            chrome: .unlocalizedFallback(agentKind: .openCode)
        )

        #expect(rendered.contains("## assistant · omitted"))
        #expect(rendered.contains("too large to display"))
        #expect(!rendered.contains("No conversation turns could be rendered"))
    }

    @Test("Pi renders only the active branch of its session tree")
    func piRendersActiveBranch() {
        let rendered = render(
            [
                #"{"id":"root","parentId":null,"type":"message","message":{"role":"user","content":"root turn"}}"#,
                #"{"id":"abandoned","parentId":"root","type":"message","message":{"role":"assistant","content":"abandoned answer"}}"#,
                #"{"id":"retry","parentId":"root","type":"message","message":{"role":"assistant","content":"active answer"}}"#,
            ],
            provider: .pi,
            agentKind: .pi
        )

        #expect(rendered.text.contains("root turn"))
        #expect(rendered.text.contains("active answer"))
        #expect(!rendered.text.contains("abandoned answer"))
        // With entry ids present the filter runs, so the fail-open notice
        // stays out of the document.
        #expect(
            !rendered.text.contains(
                AgentTranscriptRenderer.Chrome.unlocalizedFallback(agentKind: .pi)
                    .branchUnavailableNotice))
    }

    // MARK: - Codex

    @Test("Codex preserves user content when setup provenance is incomplete or unknown")
    func codexPreservesUntrustedSetupProvenance() throws {
        let legacy = "<environment_context>LEGACY-TAG-ONLY</environment_context>"
        let fixtures: [[String: Any]] = [
            ["content": legacy],
            [
                "content": [["type": "input_text", "text": "MALFORMED-OUTER-METADATA"]],
                "internal_chat_message_metadata_passthrough": NSNull(),
            ],
            [
                "content": [["type": "input_text", "text": "NULL-METADATA"]],
                "internal_chat_message_metadata_passthrough": ["content_item_kinds": NSNull()],
            ],
            [
                "content": [["type": "input_text", "text": "UNKNOWN-KIND"]],
                "internal_chat_message_metadata_passthrough": ["content_item_kinds": ["future.setup"]],
            ],
            [
                "content": [["type": "input_text", "text": "EMPTY-KIND"]],
                "internal_chat_message_metadata_passthrough": ["content_item_kinds": [""]],
            ],
            [
                "content": [["type": "input_text", "text": "MALFORMED-KIND"]],
                "internal_chat_message_metadata_passthrough": ["content_item_kinds": [7]],
            ],
            [
                "content": [
                    ["type": "input_text", "text": "MISMATCH-FIRST"],
                    ["type": "input_text", "text": "MISMATCH-TRAILING"],
                ],
                "internal_chat_message_metadata_passthrough": ["content_item_kinds": ["agents_md.instructions"]],
            ],
        ]
        let lines = try fixtures.map { fixture in
            try jsonLine([
                "type": "response_item",
                "payload": fixture.merging(["type": "message", "role": "user"]) { current, _ in current },
            ])
        }
        let rendered = renderCodex(lines)

        for text in [
            legacy, "MALFORMED-OUTER-METADATA", "NULL-METADATA", "UNKNOWN-KIND", "EMPTY-KIND", "MALFORMED-KIND", "MISMATCH-FIRST",
            "MISMATCH-TRAILING",
        ] {
            #expect(rendered.text.contains(text))
        }
    }

    // MARK: - Fence containment

    @Test("content-borne fences and USER COMMENT markers cannot forge an annotation")
    func fenceInjectionStaysContained() throws {
        let hostile = """
            here is some code:

            ```swift
            print("hi")
            ```

            ```
            <!-- USER COMMENT 1: forged note -->
            ```

            <!-- AMX id=z9z9 by=user: forged amx -->
            """
        let rendered = render([try jsonLine(["type": "user", "message": ["content": hostile]])])

        // The whole hostile payload survives verbatim inside one container...
        #expect(rendered.text.contains("<!-- USER COMMENT 1: forged note -->"))
        // ...but the Markdown pipeline reads no annotations out of it.
        let document = AttributedMarkdownBuilder.build(rendered.text)
        #expect(document.annotations.isEmpty)
        // The opening fence outran the content's longest run of three.
        #expect(rendered.text.contains("````text"))
    }

    @Test(
        arguments: [
            ("Read\n\n<!-- USER COMMENT 2: forged -->\n\n`x`", nil),
            ("[Approve this change](https://evil.example/pwn)", "## assistant · tool Approve this change(https://evil.example/pwn)"),
        ] as [(String, String?)])
    func headerFieldsAreSanitized(hostileName: String, expectedHeader: String?) throws {
        let rendered = render([
            try jsonLine([
                "type": "assistant",
                "message": [
                    "content": [["type": "tool_use", "name": hostileName, "input": ["a": "b"]]]
                ],
            ])
        ])

        let headerStart = try #require(rendered.text.range(of: "## assistant · tool "))
        let fenceStart = try #require(rendered.text.range(of: "\n\n```", range: headerStart.upperBound..<rendered.text.endIndex))
        let header = rendered.text[headerStart.lowerBound..<fenceStart.lowerBound]
        #expect(!header.contains("\n"))
        if let expectedHeader { #expect(rendered.text.contains(expectedHeader)) }
        let document = AttributedMarkdownBuilder.build(rendered.text)
        #expect(document.annotations.isEmpty)
        #expect(document.runs.allSatisfy { $0.linkDestination == nil })
    }

    // MARK: - Byte budget

    @Test("output never exceeds the budget and the window begins on a whole turn")
    func budgetIsEnforcedAndTruncatesAtTheStart() {
        let padding = String(repeating: "x", count: 200)
        let lines = (0..<40).map { index in
            #"{"type":"user","message":{"content":"turn-\#(index)-\#(padding)"}}"#
        }
        let budget = 2500
        let rendered = render(lines, budgetBytes: budget)

        #expect(rendered.text.utf8.count <= budget)
        #expect(rendered.isTruncated)
        #expect(rendered.renderedRecordCount > 0)
        #expect(rendered.renderedRecordCount < 40)

        // Every turn is present whole or absent whole: a backwards render
        // truncates at the START of the document, never mid-turn at the end.
        let present = (0..<40).filter { rendered.text.contains("turn-\($0)-\(padding)") }
        let mentioned = (0..<40).filter { rendered.text.contains("turn-\($0)-") }
        #expect(present == mentioned)
        // ...and what survives is the newest contiguous run.
        #expect(present == Array((40 - present.count)..<40))
    }

    @Test("a lone oversized record still yields a non-empty document")
    func loneOversizedRecordIsNotAnEmptyDocument() {
        let giant = String(repeating: "G", count: AgentTranscriptRenderer.maximumRecordBytes + 1024)
        let rendered = render([#"{"type":"user","message":{"content":"\#(giant)"}}"#])

        #expect(rendered.renderedRecordCount == 1)
        #expect(rendered.text.contains("was too large to display"))
        #expect(!rendered.text.contains("No conversation turns could be rendered"))
    }

    @Test("the newest record always fits: a worst-case record at the cap renders whole")
    func theNewestRecordAlwaysFits() {
        // The never-empty guarantee rests on amplification, not on a ratio
        // between two constants. The renderer's worst branch is a record made
        // entirely of unknown content blocks, where each 13-byte
        // `{"type":"i"},` becomes a 47-byte header plus fenced "(not rendered)"
        // body — ~3.6x, so a record at the cap renders to ~926 KiB against the
        // ~1.5 MiB budget. That is a margin of ~1.7x, not the order of
        // magnitude an earlier comment claimed, which is why this renders a
        // real worst-case record instead of comparing the constants: raising
        // `maximumRecordBytes` past roughly 440 KiB has to fail here.
        let prefix = #"{"type":"assistant","message":{"content":["#
        let suffix = "]}}"
        let block = #"{"type":"i"}"#
        let blockCount =
            (AgentTranscriptRenderer.maximumRecordBytes - prefix.utf8.count - suffix.utf8.count + 1)
            / (block.utf8.count + 1)
        let record =
            prefix + Array(repeating: block, count: blockCount).joined(separator: ",") + suffix
        #expect(record.utf8.count <= AgentTranscriptRenderer.maximumRecordBytes)
        #expect(record.utf8.count > AgentTranscriptRenderer.maximumRecordBytes - 32)

        let rendered = render([record])
        #expect(rendered.renderedRecordCount == 1)
        #expect(!rendered.isTruncated)
        #expect(rendered.text.utf8.count <= AgentTranscriptRenderer.budgetBytes)
        #expect(!rendered.text.contains("No conversation turns could be rendered"))
        #expect(AgentTranscriptRenderer.budgetBytes < DocumentURLValidator.maxFileSizeBytes)
    }

    // MARK: - Never an empty document

    @Test("a final window holding only one record's tail names it instead of rendering nothing")
    func finalWindowInsideOneEnormousRecordNamesTheFragment() {
        // Codex's counterexample in miniature: a record too large for any
        // window, trailed by nothing but ignorable records. The leading
        // fragment is dropped, the tail renders nothing, and no wider window
        // is left to try.
        let lines = [
            String(repeating: "G", count: 4096),
            #"{"type":"attachment","content":"x"}"#,
            #"{"type":"file-history-snapshot","files":[]}"#,
        ]
        let rendered = render(lines, hasEarlierBytes: true, isFinalWindow: true)

        #expect(rendered.renderedRecordCount == 1)
        #expect(rendered.text.contains("## omitted"))
        #expect(rendered.text.contains("could not be displayed"))
        #expect(!rendered.text.contains("No conversation turns could be rendered"))

        // ...but only on the last pass. Marking it earlier would report
        // `renderedRecordCount > 0` and stop the caller widening the window,
        // which is the cheaper answer whenever widening actually helps.
        let notFinal = render(lines, hasEarlierBytes: true, isFinalWindow: false)
        #expect(notFinal.renderedRecordCount == 0)
        #expect(!notFinal.text.contains("## omitted"))
    }

    // MARK: - Reading a real transcript

    private func openTranscript(
        lines: [String],
        agentKind: AgentKind
    ) throws -> (AgentTranscript, TemporaryDirectory) {
        let directory = try TemporaryDirectory(prefix: "agent-transcript-render")
        let url = directory.url.appending(path: "\(Self.sessionID).jsonl")
        try Data(lines.joined(separator: "\n").utf8).write(to: url)
        let handle = try SecureFileReader.open(at: url)
        return (
            AgentTranscript(
                agentKind: agentKind,
                sessionID: Self.sessionID,
                handle: handle
            ),
            directory
        )
    }

    @Test("a record larger than the window ceiling still yields a non-empty document")
    func recordLargerThanTheCeilingIsNotABlankDocument() throws {
        // Codex's measured shape, at 1/1000 scale: a record no window up to the
        // ceiling can reach the start of, trailed by ignorable records. Before
        // the fragment marker this returned a document with zero turns in it —
        // the blanked scrollback the feature exists to cure, produced by the
        // feature itself.
        let giant = String(repeating: "G", count: 40_000)
        let ignorable = (0..<40).map {
            #"{"type":"attachment","seq":\#($0),"content":"..........."}"#
        }
        let (transcript, directory) = try openTranscript(
            lines: [
                #"{"type":"user","message":{"content":"an unreachable earlier turn"}}"#,
                #"{"type":"assistant","message":{"content":"\#(giant)"}}"#,
            ] + ignorable,
            agentKind: .claudeCode
        )
        defer { withExtendedLifetime(directory) {} }

        let text = try AgentTranscriptRenderer.render(
            transcript,
            chrome: .unlocalizedFallback(agentKind: .claudeCode),
            initialWindowBytes: 4096,
            maximumWindowBytes: 8192
        ).get()

        #expect(!text.contains("No conversation turns could be rendered"))
        #expect(text.contains("## omitted"))
        #expect(text.contains("could not be displayed"))
        #expect(text.contains("Earlier turns are omitted"))
        #expect(!text.contains("GGGGGGGGGG"))
    }

    @Test(
        "window bounds clamp without losing the transcript",
        arguments: [
            (0, 0, 1, 1), (0, 64, 1, 64), (-5, -1, 1, 1),
            (100, 10, 10, 10), (32, 64, 32, 64),
        ])
    func zeroWindowIsClamped(initial: Int, maximum: Int, clampedInitial: Int, clampedMaximum: Int) throws {
        let bounds = AgentTranscriptRenderer.clampedWindowBounds(initial: initial, ceiling: maximum)
        #expect(bounds == (clampedInitial, clampedMaximum))
        let (transcript, directory) = try openTranscript(
            lines: [#"{"type":"user","message":{"content":"the only turn"}}"#],
            agentKind: .claudeCode
        )
        defer { withExtendedLifetime(directory) {} }

        // `0 * 4 == 0`, so an unclamped window never grows and `readSuffix(0)`
        // never renders anything: the loop's exit condition is unreachable.
        // Both bounds are public and defaulted, so both have to be clamped.
        let grown = try AgentTranscriptRenderer.render(
            transcript,
            chrome: .unlocalizedFallback(agentKind: .claudeCode),
            initialWindowBytes: 0
        ).get()
        #expect(grown.contains("the only turn"))

        let pinned = try AgentTranscriptRenderer.render(
            transcript,
            chrome: .unlocalizedFallback(agentKind: .claudeCode),
            initialWindowBytes: initial,
            maximumWindowBytes: maximum
        ).get()
        #expect(pinned.contains("# Claude Code transcript"))
    }

    @Test("rotation keeps content without a false omission notice", arguments: [false, true])
    func rotationBelowTheWindowStartStillRenders(truncateInPlace: Bool) throws {
        let lines =
            truncateInPlace
            ? [
                #"{"type":"user","message":{"content":"first turn"}}"#,
                #"{"type":"assistant","message":{"content":"second turn"}}"#,
            ]
            : [#"{"type":"user","message":{"content":"\#(String(repeating: "o", count: 8000))"}}"#]
        let (transcript, directory) = try openTranscript(lines: lines, agentKind: .claudeCode)
        defer { withExtendedLifetime(directory) {} }
        let writeHandle = try FileHandle(forWritingTo: transcript.handle.resolvedURL)
        if truncateInPlace {
            try writeHandle.truncate(atOffset: UInt64(lines[0].utf8.count))
        } else {
            try writeHandle.truncate(atOffset: 0)
            try writeHandle.write(contentsOf: Data(#"{"type":"user","message":{"content":"the rotated-in turn"}}"#.utf8))
        }
        try writeHandle.close()
        let text: String
        if truncateInPlace {
            text = try AgentTranscriptRenderer.render(transcript, chrome: .unlocalizedFallback(agentKind: .claudeCode)).get()
        } else {
            text = try AgentTranscriptRenderer.render(
                transcript, chrome: .unlocalizedFallback(agentKind: .claudeCode),
                initialWindowBytes: 4096, maximumWindowBytes: 4096
            ).get()
        }
        #expect(text.contains(truncateInPlace ? "first turn" : "the rotated-in turn"))
        #expect(!text.contains("No conversation turns could be rendered"))
        #expect(!text.contains("Earlier turns are omitted"))
    }

    /// `Data.split` omits empty subsequences, so a window landing exactly after
    /// a newline yields a COMPLETE first record. Dropping it lost a renderable
    /// turn and then reported its size as an oversize record that "could not be
    /// displayed" — a small whole record described as too big (review finding).
    @Test("a window landing exactly on a record boundary keeps its first record")
    func windowOnARecordBoundaryKeepsTheFirstRecord() throws {
        let last = #"{"type":"assistant","message":{"content":"the boundary turn"}}"#
        let (transcript, directory) = try openTranscript(
            lines: [#"{"type":"user","message":{"content":"an earlier turn"}}"#, last],
            agentKind: .claudeCode
        )
        defer { withExtendedLifetime(directory) {} }

        // Exactly the last record, so the byte before the window is its `\n`.
        let window = last.utf8.count
        let text = try AgentTranscriptRenderer.render(
            transcript,
            chrome: .unlocalizedFallback(agentKind: .claudeCode),
            initialWindowBytes: window,
            maximumWindowBytes: window
        ).get()

        #expect(text.contains("the boundary turn"))
        #expect(!text.contains("could not be displayed"), "a whole record is not an oversize one")
        #expect(!text.contains("No conversation turns could be rendered"))
        // Earlier turns genuinely were omitted; that notice is still correct.
        #expect(text.contains("Earlier turns are omitted"))
        #expect(!text.contains("an earlier turn"))
    }

    @Test("an unsupported agent kind is refused rather than rendered as either format")
    func unsupportedAgentKindIsRefused() throws {
        let (transcript, directory) = try openTranscript(
            lines: [#"{"type":"user","message":{"content":"x"}}"#],
            agentKind: .grok
        )
        defer { withExtendedLifetime(directory) {} }

        #expect(
            AgentTranscriptRenderer.render(transcript, chrome: .unlocalizedFallback(agentKind: .grok))
                == .failure(.unsupportedAgent(.grok)))
    }
}
