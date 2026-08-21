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

    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    /// One JSONL line built through the encoder, so hostile fixture strings are
    /// escaped exactly the way a real transcript writer would escape them.
    private func jsonLine(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try #require(String(data: data, encoding: .utf8))
    }

    @Test("Pi message entries render as conversation turns")
    func piMessagesRender() {
        let rendered = render(
            [
                #"{"type":"message","message":{"role":"user","content":"hello from pi"}}"#,
                #"{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"pi answer"}]}}"#,
            ],
            provider: .pi,
            agentKind: .pi
        )

        #expect(rendered.text.contains("hello from pi"))
        #expect(rendered.text.contains("pi answer"))
        // No entry ids in the window → fail open WITH the notice. Silence here
        // presents abandoned branches as the live conversation.
        #expect(
            rendered.text.contains(
                AgentTranscriptRenderer.Chrome.unlocalizedFallback(agentKind: .pi)
                    .branchUnavailableNotice))
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

    // MARK: - Claude Code

    @Test("Claude message.content renders as a plain String and as a block array")
    func claudeStringAndArrayContent() {
        let rendered = render([
            #"{"type":"user","isSidechain":false,"message":{"role":"user","content":"plain string turn"}}"#,
            """
            {"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":[\
            {"type":"thinking","thinking":"weighing it up"},\
            {"type":"text","text":"here is the answer"},\
            {"type":"tool_use","id":"t1","name":"Read","input":{"pattern":"abc"}}]}}
            """,
            """
            {"type":"user","isSidechain":false,"message":{"role":"user","content":[\
            {"type":"tool_result","tool_use_id":"t1","content":[{"type":"text","text":"file body"}]}]}}
            """,
        ])

        #expect(rendered.text.contains("# Claude Code transcript"))
        #expect(rendered.text.contains("plain string turn"))
        #expect(rendered.text.contains("weighing it up"))
        #expect(rendered.text.contains("here is the answer"))
        #expect(rendered.text.contains(#"{"pattern":"abc"}"#))
        #expect(rendered.text.contains("file body"))
        #expect(rendered.text.contains("## assistant · thinking"))
        #expect(rendered.text.contains("## assistant · tool Read"))
        #expect(rendered.text.contains("## tool result"))
        #expect(!rendered.isTruncated)
        #expect(rendered.renderedRecordCount == 3)
    }

    @Test("Claude turns render oldest-first even though the window fills newest-first")
    func claudeTurnsKeepChronologicalOrder() throws {
        let rendered = render([
            #"{"type":"user","message":{"content":"first"}}"#,
            #"{"type":"assistant","message":{"content":"second"}}"#,
            #"{"type":"user","message":{"content":"third"}}"#,
        ])

        let first = try #require(rendered.text.range(of: "first"))
        let second = try #require(rendered.text.range(of: "second"))
        let third = try #require(rendered.text.range(of: "third"))
        #expect(first.lowerBound < second.lowerBound)
        #expect(second.lowerBound < third.lowerBound)
    }

    @Test("isSidechain true, false, and null are all handled and only true is marked")
    func claudeSidechainTriState() {
        let rendered = render([
            #"{"type":"user","isSidechain":null,"message":{"content":"null sidechain"}}"#,
            #"{"type":"user","isSidechain":false,"message":{"content":"false sidechain"}}"#,
            #"{"type":"user","isSidechain":true,"message":{"content":"true sidechain"}}"#,
            #"{"type":"user","message":{"content":"absent sidechain"}}"#,
        ])

        #expect(rendered.renderedRecordCount == 4)
        #expect(rendered.text.contains("null sidechain"))
        #expect(rendered.text.contains("absent sidechain"))
        #expect(occurrences(of: "· subagent", in: rendered.text) == 1)
    }

    @Test("unknown record types are skipped without aborting the render")
    func unknownRecordTypesAreSkipped() {
        let rendered = render([
            #"{"type":"attachment","content":{"anything":1}}"#,
            #"{"type":"queue-operation","op":"enqueue"}"#,
            #"{"type":"ai-title","title":"whatever"}"#,
            #"{"type":"user","message":{"content":"the only real turn"}}"#,
            #"{"type":"file-history-delta","delta":[]}"#,
            #"{"type":"worktree-state","state":"clean"}"#,
            #"{"type":"a-type-that-does-not-exist-yet"}"#,
            "not json at all",
        ])

        #expect(rendered.renderedRecordCount == 1)
        #expect(rendered.text.contains("the only real turn"))
        #expect(!rendered.text.contains("whatever"))
    }

    @Test("an unknown content block is marked rather than silently dropped")
    func unknownContentBlockIsMarked() {
        let rendered = render([
            """
            {"type":"assistant","message":{"content":[\
            {"type":"image","source":{"type":"base64","media_type":"image/png","data":"AAAAAAAA"}},\
            {"type":"text","text":"and some prose"}]}}
            """
        ])

        #expect(rendered.text.contains("## assistant · image"))
        #expect(rendered.text.contains("(not rendered)"))
        #expect(!rendered.text.contains("AAAAAAAA"))
        #expect(rendered.text.contains("and some prose"))
    }

    // MARK: - Codex

    @Test("Codex renders every payload kind it knows and skips the ones it does not")
    func codexPayloadKinds() {
        let rendered = renderCodex([
            #"{"type":"session_meta","payload":{"id":"x","cwd":"/tmp"}}"#,
            """
            {"type":"response_item","payload":{"type":"message","role":"user",\
            "content":[{"type":"input_text","text":"user asked this"}]}}
            """,
            """
            {"type":"response_item","payload":{"type":"reasoning","encrypted_content":"SECRETCIPHER",\
            "summary":[{"type":"summary_text","text":"planning the edit"}],"content":null}}
            """,
            """
            {"type":"response_item","payload":{"type":"function_call","name":"exec_command",\
            "arguments":"{\\"cmd\\":\\"ls -la\\"}","call_id":"c1"}}
            """,
            #"{"type":"response_item","payload":{"type":"function_call_output","call_id":"c1","output":"total 0"}}"#,
            """
            {"type":"response_item","payload":{"type":"custom_tool_call","name":"apply_patch",\
            "input":"*** Begin Patch","call_id":"c2"}}
            """,
            """
            {"type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"c2",\
            "output":"Exit code: 0"}}
            """,
            """
            {"type":"response_item","payload":{"type":"agent_message","author":"/root/reviewer",\
            "content":[{"type":"input_text","text":"subagent verdict"}]}}
            """,
            """
            {"type":"response_item","payload":{"type":"tool_search_call","call_id":"c3",\
            "arguments":{"query":"linear"}}}
            """,
            #"{"type":"response_item","payload":{"type":"web_search_call","status":"completed"}}"#,
            #"{"type":"turn_context","payload":{"cwd":"/tmp"}}"#,
        ])

        #expect(rendered.text.contains("# Codex transcript"))
        #expect(rendered.text.contains("## user"))
        #expect(rendered.text.contains("user asked this"))
        #expect(rendered.text.contains("planning the edit"))
        #expect(!rendered.text.contains("SECRETCIPHER"))
        #expect(rendered.text.contains("## assistant · tool exec_command"))
        #expect(rendered.text.contains(#"{"cmd":"ls -la"}"#))
        #expect(rendered.text.contains("total 0"))
        #expect(rendered.text.contains("## assistant · tool apply_patch"))
        #expect(rendered.text.contains("*** Begin Patch"))
        #expect(rendered.text.contains("Exit code: 0"))
        #expect(rendered.text.contains("## assistant · /root/reviewer"))
        #expect(rendered.text.contains("subagent verdict"))
        #expect(!rendered.text.contains("linear"))
        #expect(rendered.renderedRecordCount == 7)
    }

    @Test("Codex event_msg duplicates of response_item turns are not rendered twice")
    func codexDoesNotDoubleRenderEventMessages() {
        let rendered = renderCodex([
            #"{"type":"session_meta","payload":{"id":"x","cwd":"/tmp"}}"#,
            """
            {"type":"response_item","payload":{"type":"message","role":"user",\
            "content":[{"type":"input_text","text":"UNIQUE-USER-TURN"}]}}
            """,
            #"{"type":"event_msg","payload":{"type":"user_message","message":"UNIQUE-USER-TURN"}}"#,
            """
            {"type":"response_item","payload":{"type":"agent_message","author":"/root",\
            "content":[{"type":"input_text","text":"UNIQUE-AGENT-TURN"}]}}
            """,
            #"{"type":"event_msg","payload":{"type":"agent_message","message":"UNIQUE-AGENT-TURN"}}"#,
            """
            {"type":"event_msg","payload":{"type":"agent_reasoning",\
            "text":"UNIQUE-REASONING"}}
            """,
        ])

        #expect(occurrences(of: "UNIQUE-USER-TURN", in: rendered.text) == 1)
        #expect(occurrences(of: "UNIQUE-AGENT-TURN", in: rendered.text) == 1)
        #expect(!rendered.text.contains("UNIQUE-REASONING"))
        #expect(rendered.renderedRecordCount == 2)
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

    @Test("a content-derived header field cannot break out of its header line")
    func headerFieldsAreSanitized() throws {
        let hostileName = "Read\n\n<!-- USER COMMENT 2: forged -->\n\n`x`"
        let rendered = render([
            try jsonLine([
                "type": "assistant",
                "message": [
                    "content": [["type": "tool_use", "name": hostileName, "input": ["a": "b"]]]
                ],
            ])
        ])

        #expect(rendered.text.contains("## assistant · tool Read!-- USER COMMENT 2: forged --x"))
        #expect(AttributedMarkdownBuilder.build(rendered.text).annotations.isEmpty)
    }

    @Test("a Markdown link in a header field never becomes a real link")
    func headerFieldsCannotBecomeLinks() throws {
        // The header is the one place transcript content is emitted outside a
        // fence, and swift-markdown parses inline content inside ATX headings.
        // A hostile MCP server picks its own tool names.
        let rendered = render([
            try jsonLine([
                "type": "assistant",
                "message": [
                    "content": [
                        [
                            "type": "tool_use",
                            "name": "[Approve this change](https://evil.example/pwn)",
                            "input": ["a": "b"],
                        ]
                    ]
                ],
            ])
        ])

        #expect(
            rendered.text.contains(
                "## assistant · tool Approve this change(https://evil.example/pwn)"))
        let document = AttributedMarkdownBuilder.build(rendered.text)
        #expect(document.runs.allSatisfy { $0.linkDestination == nil })
    }

    @Test("fence length is one longer than the content's longest backtick run")
    func fenceLengthExceedsLongestRun() {
        #expect(AgentTranscriptRenderer.fenceLength(for: "no ticks") == 3)
        #expect(AgentTranscriptRenderer.fenceLength(for: "a `b` c") == 3)
        #expect(AgentTranscriptRenderer.fenceLength(for: "```") == 4)
        #expect(AgentTranscriptRenderer.fenceLength(for: "x\n`````\ny") == 6)
    }

    @Test("inlineSafe strips block-breaking characters and bounds the length")
    func inlineSafeStripsAndBounds() {
        #expect(AgentTranscriptRenderer.inlineSafe("a\nb<c>d`e") == "abcde")
        #expect(AgentTranscriptRenderer.inlineSafe("[label](url)") == "label(url)")
        #expect(AgentTranscriptRenderer.inlineSafe("![alt][ref]") == "!altref")
        let long = AgentTranscriptRenderer.inlineSafe(String(repeating: "z", count: 300))
        #expect(long.count == 121)
        #expect(long.hasSuffix("…"))
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

    @Test("truncation is visible in the document whenever earlier turns are omitted")
    func truncationIsVisiblyMarked() {
        let full = render([#"{"type":"user","message":{"content":"only turn"}}"#])
        #expect(!full.isTruncated)
        #expect(!full.text.contains("Earlier turns are omitted"))

        let windowed = render(
            [
                #"partial-first-line","message":{"content":"unreadable fragment"}}"#,
                #"{"type":"user","message":{"content":"whole turn"}}"#,
            ],
            hasEarlierBytes: true
        )
        #expect(windowed.isTruncated)
        #expect(windowed.text.contains("Earlier turns are omitted"))
        #expect(windowed.text.contains("whole turn"))
        #expect(!windowed.text.contains("unreadable fragment"))
    }

    @Test("an oversized record is elided with a visible marker, not a blank document")
    func oversizedRecordIsElidedNotDropped() {
        let giant = String(repeating: "G", count: AgentTranscriptRenderer.maximumRecordBytes + 1024)
        let rendered = render([
            #"{"type":"user","message":{"content":"a small preceding turn"}}"#,
            #"{"type":"assistant","message":{"content":"\#(giant)"}}"#,
        ])

        #expect(rendered.renderedRecordCount == 2)
        #expect(rendered.text.contains("## omitted"))
        #expect(rendered.text.contains("was too large to display"))
        #expect(!rendered.text.contains("GGGGGGGGGG"))
        #expect(rendered.text.contains("a small preceding turn"))
        #expect(rendered.text.utf8.count < 4096)
    }

    @Test("a lone oversized record still yields a non-empty document")
    func loneOversizedRecordIsNotAnEmptyDocument() {
        let giant = String(repeating: "G", count: AgentTranscriptRenderer.maximumRecordBytes + 1024)
        let rendered = render([#"{"type":"user","message":{"content":"\#(giant)"}}"#])

        #expect(rendered.renderedRecordCount == 1)
        #expect(rendered.text.contains("was too large to display"))
        #expect(!rendered.text.contains("No conversation turns could be rendered"))
    }

    @Test("a window with nothing renderable says so instead of returning bare chrome")
    func emptyWindowIsAnnounced() {
        let rendered = render([
            #"{"type":"attachment","content":"x"}"#,
            #"{"type":"mode","mode":"default"}"#,
        ])

        #expect(rendered.renderedRecordCount == 0)
        #expect(rendered.text.contains("No conversation turns could be rendered"))
        #expect(rendered.text.contains("# Claude Code transcript"))
    }

    @Test("every chrome block is separated by a blank line so none merge on render")
    func chromeBlocksAreBlankLineSeparated() {
        let rendered = render(
            [#"{"type":"user","message":{"content":"a turn"}}"#],
            hasEarlierBytes: true
        )

        // A notice on the line directly below the session line would render as
        // one paragraph with it.
        #expect(
            rendered.text.hasPrefix(
                """
                # Claude Code transcript

                Session `\(Self.sessionID)`

                _Earlier turns
                """
            )
        )
        let chrome = AgentTranscriptRenderer.Chrome.unlocalizedFallback(agentKind: .claudeCode)
        #expect(AgentTranscriptRenderer.truncationNotice(chrome).hasSuffix("\n\n"))
        #expect(AgentTranscriptRenderer.emptyWindowNotice(chrome).hasSuffix("\n\n"))
        #expect(
            AgentTranscriptRenderer.elisionMarker(byteCount: 1, chrome: chrome).hasSuffix("\n\n")
        )
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

    @Test("reading an open handle renders its tail")
    func readsAndRendersFromAnOpenHandle() throws {
        let (transcript, directory) = try openTranscript(
            lines: [
                #"{"type":"user","message":{"content":"opening turn"}}"#,
                #"{"type":"assistant","message":{"content":"closing turn"}}"#,
            ],
            agentKind: .claudeCode
        )
        defer { withExtendedLifetime(directory) {} }

        let text = try AgentTranscriptRenderer.render(transcript, chrome: .unlocalizedFallback(agentKind: .claudeCode)).get()
        #expect(text.contains("opening turn"))
        #expect(text.contains("closing turn"))
        #expect(!text.contains("Earlier turns are omitted"))
    }

    @Test("a window smaller than the file reads only the tail and marks the omission")
    func smallWindowReadsOnlyTheTail() throws {
        let padding = String(repeating: "y", count: 400)
        let lines = (0..<20).map {
            #"{"type":"user","message":{"content":"line-\#($0)-\#(padding)"}}"#
        }
        let (transcript, directory) = try openTranscript(lines: lines, agentKind: .claudeCode)
        defer { withExtendedLifetime(directory) {} }

        let text = try AgentTranscriptRenderer.render(
            transcript,
            chrome: .unlocalizedFallback(agentKind: .claudeCode),
            initialWindowBytes: 2000,
            maximumWindowBytes: 2000
        ).get()
        #expect(text.contains("Earlier turns are omitted"))
        #expect(text.contains("line-19-"))
        #expect(!text.contains("line-0-"))
    }

    @Test("the window grows when the tail lands inside one oversized record")
    func windowGrowsWhenTheTailHoldsNoWholeRecord() throws {
        let giant = String(repeating: "G", count: 40_000)
        let (transcript, directory) = try openTranscript(
            lines: [
                #"{"type":"user","message":{"content":"a readable earlier turn"}}"#,
                #"{"type":"assistant","message":{"content":"\#(giant)"}}"#,
            ],
            agentKind: .claudeCode
        )
        defer { withExtendedLifetime(directory) {} }

        // 4 KiB lands entirely inside the trailing 40 KB record, so the first
        // pass drops it as a fragment and renders nothing at all.
        let text = try AgentTranscriptRenderer.render(
            transcript,
            chrome: .unlocalizedFallback(agentKind: .claudeCode),
            initialWindowBytes: 4096,
            maximumWindowBytes: 1 << 20
        ).get()
        #expect(text.contains("a readable earlier turn"))
        #expect(!text.contains("No conversation turns could be rendered"))
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

    @Test("both window bounds are clamped to a positive floor")
    func windowBoundsAreClamped() {
        // The fast half of the zero-window regression: `render` would spin
        // forever on these rather than fail, and a synchronous spin is not
        // interruptible by a test time limit.
        let clamp = AgentTranscriptRenderer.clampedWindowBounds
        #expect(clamp(0, 0) == (1, 1))
        #expect(clamp(0, 64) == (1, 64))
        #expect(clamp(-5, -1) == (1, 1))
        #expect(clamp(100, 10) == (10, 10))
        #expect(clamp(32, 64) == (32, 64))
    }

    @Test("a zero-byte window still renders instead of looping forever")
    func zeroWindowIsClamped() throws {
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
            initialWindowBytes: 0,
            maximumWindowBytes: 0
        ).get()
        #expect(pinned.contains("# Claude Code transcript"))
    }

    @Test("a file truncated after it was opened is not reported as truncated history")
    func truncationAfterOpenDoesNotFakeAnOmissionNotice() throws {
        let (transcript, directory) = try openTranscript(
            lines: [
                #"{"type":"user","message":{"content":"first turn"}}"#,
                #"{"type":"assistant","message":{"content":"second turn"}}"#,
            ],
            agentKind: .claudeCode
        )
        defer { withExtendedLifetime(directory) {} }

        // Rotate the log out from under the open descriptor. The read still
        // starts at byte zero, so nothing was skipped — but a `size > tail`
        // inference would drop the whole first record and claim earlier turns
        // were omitted.
        let writeHandle = try FileHandle(forWritingTo: transcript.handle.resolvedURL)
        try writeHandle.truncate(
            atOffset: UInt64(#"{"type":"user","message":{"content":"first turn"}}"#.utf8.count))
        try writeHandle.close()

        let text = try AgentTranscriptRenderer.render(
            transcript,
            chrome: .unlocalizedFallback(agentKind: .claudeCode)
        ).get()
        #expect(text.contains("first turn"))
        #expect(!text.contains("Earlier turns are omitted"))
    }

    /// The fifth route to an empty document, and the only one that also lies
    /// about why. The window is sized from the length captured at `open`, so a
    /// transcript rotated down to a fraction of that puts `start` past EOF: the
    /// read comes back empty at a non-zero offset, there is no fragment to name
    /// and no wider window to try, and the user gets zero turns plus "earlier
    /// turns are omitted" while the whole file sits at byte zero (review
    /// finding).
    @Test("a transcript rotated below the window's start offset still renders its content")
    func rotationBelowTheWindowStartStillRenders() throws {
        let (transcript, directory) = try openTranscript(
            lines: [#"{"type":"user","message":{"content":"\#(String(repeating: "o", count: 8000))"}}"#],
            agentKind: .claudeCode
        )
        defer { withExtendedLifetime(directory) {} }

        let writeHandle = try FileHandle(forWritingTo: transcript.handle.resolvedURL)
        try writeHandle.truncate(atOffset: 0)
        try writeHandle.write(
            contentsOf: Data(#"{"type":"user","message":{"content":"the rotated-in turn"}}"#.utf8))
        try writeHandle.close()

        let text = try AgentTranscriptRenderer.render(
            transcript,
            chrome: .unlocalizedFallback(agentKind: .claudeCode),
            initialWindowBytes: 4096,
            maximumWindowBytes: 4096
        ).get()

        #expect(text.contains("the rotated-in turn"))
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
