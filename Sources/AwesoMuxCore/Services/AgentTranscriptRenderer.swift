import AwesoMuxBridgeProtocol
import Foundation
import SecureFileIO

// MARK: - Renderer

/// Turns an agent's JSONL transcript into a bounded Markdown document.
///
/// Two things shape every decision here.
///
/// **The byte budget is the feature.** `DocumentURLValidator.maxFileSizeBytes`
/// *rejects* an oversize document rather than truncating it, so a renderer that
/// overshoots shows the user an error where the transcript should be. Real
/// transcripts run to 27 MB (Claude) and 196 MB (Codex), and a single JSONL
/// record has been measured at 57,361,962 bytes, so the budget is enforced
/// *during* accumulation. Nothing here ever materializes a record it has not
/// first measured.
///
/// **The output is plain text in fences, not rich Markdown.** The document is
/// "what the terminal would have shown", and transcript content is untrusted
/// prose that routinely contains its own code fences and literal
/// `<!-- USER COMMENT n: -->` markers — which `AttributedMarkdownBuilder` parses
/// as real annotations. Every piece of transcript content therefore goes inside
/// a fence sized to contain it, and nothing content-derived reaches the document
/// outside a fence without passing through `inlineSafe(_:)` first.
public enum AgentTranscriptRenderer {

    // MARK: Budgets

    /// The rendered document's hard ceiling.
    ///
    /// The binding constraint is layout, not file size. `DocumentURLValidator`
    /// records that whole-document TextKit 2 layout costs roughly 138 MB per
    /// MiB of document, so a transcript rendered up to the viewer's own file cap
    /// asks for a couple of hundred megabytes of layout on its own. At that size
    /// the pane has been seen to paint blank until a tab switch forces it to
    /// rebuild — a static document, no refresh in flight, and nothing logged.
    ///
    /// It cannot go much below this. The never-empty guarantee needs the newest
    /// record to render whole even in the renderer's worst branch, which
    /// amplifies about 3.6x — so a record at `maximumRecordBytes` renders to
    /// roughly 926 KiB, and `theNewestRecordAlwaysFits` fails the moment the
    /// budget stops clearing that. One MiB keeps a working margin while cutting
    /// layout by a third; going lower means lowering `maximumRecordBytes` too,
    /// which would elide records that measurement says are worth keeping.
    ///
    /// Deliberately NOT derived from `maxFileSizeBytes`: that number governs
    /// what the viewer will open, and tying the two together encodes a
    /// relationship that was never the binding one.
    ///
    /// ponytail: a flat cap that only takes the easy third. The real fix for a
    /// transcript that wants more history is a large-document mode that does not
    /// hold whole-document layout (see `DocumentURLValidator.maxFileSizeBytes`).
    public static let budgetBytes = 1024 * 1024

    /// The largest JSONL record the renderer will parse. Anything longer is
    /// elided by its measured length alone, so a 57 MB line is never decoded.
    ///
    /// Measured over 60 of the largest local transcripts: records past this size
    /// are 0.32% of all records but 85% of all bytes.
    ///
    /// The cap is also what guarantees the document can never come back empty:
    /// the newest record under it must still fit the budget *after* rendering.
    /// Rendering is not 1:1. The worst branch is a record made entirely of
    /// unknown content blocks, where 13 input bytes (`{"type":"i"},`) become 47
    /// output bytes — an amplification of ~3.6x, not the "order of magnitude
    /// below the budget" an earlier version of this comment claimed. At this cap
    /// that is ~926 KiB of output against a ~1.5 MiB budget: a real margin of
    /// ~1.7x. `theNewestRecordAlwaysFits` renders an actual worst-case record at
    /// exactly this size rather than asserting a ratio between two constants, so
    /// raising the cap past roughly 440 KiB fails a test instead of silently
    /// voiding the guarantee.
    static let maximumRecordBytes = 256 * 1024

    /// How much of the file's tail to read on the first attempt.
    ///
    /// Sized against the two largest transcripts on the author's machine, end to
    /// end through this renderer: a 27 MB Claude session fits entirely inside the
    /// window and yields 928 KB of Markdown in 0.34 s, and a 196 MB Codex rollout
    /// yields 416 KB of Markdown in 0.24 s. Codex converts far fewer bytes than
    /// its file size suggests because the bulk of a rollout is duplicated
    /// `event_msg` records and `reasoning.encrypted_content` ciphertext, neither
    /// of which is rendered.
    ///
    /// Note: one fixed window rather than a chunked backwards walk that keeps
    /// reading until the budget is full. The window grows only for the one case a
    /// fixed size gets badly *wrong* (below); an under-filled window still yields
    /// hundreds of KB of recent conversation, which is more than a reader
    /// consumes. Switch to a chunked read if a real session is ever seen where
    /// the window, not the budget, is the binding constraint on useful history.
    public static let initialWindowBytes = 32 * 1024 * 1024

    /// The ceiling on window growth. Growth exists solely so a tail that lands
    /// entirely inside one multi-megabyte record cannot produce a document with
    /// no turns in it — which would reproduce the blank-scrollback symptom this
    /// feature exists to cure.
    public static let maximumWindowBytes = 64 * 1024 * 1024

    // MARK: Chrome

    /// The document's own words — everything in the rendered file that awesoMux
    /// wrote rather than the agent.
    ///
    /// It is an input so that every user-facing sentence in the document is
    /// composed in one place, the layer that owns copy (ADR-0014) — and so this
    /// renderer stays a pure function of its arguments, testable without a
    /// bundle or a locale. (`String(localized:)` in `AwesoMuxCore` does resolve
    /// against `Bundle.main`, and the catalog is extracted from all of
    /// `Sources`, so localizing here would *work*; it would just scatter the
    /// document's words across two modules.) Markdown structure stays in the
    /// renderer — these are sentences, not templates, so a translation can never
    /// alter the document's shape.
    public struct Chrome: Sendable {
        /// Level-1 heading naming the provider, e.g. "Claude Code transcript".
        public var title: String
        /// Label introducing the session id, e.g. "Session".
        public var sessionLabel: String
        /// Sentence shown when older turns did not fit the budget.
        public var truncationNotice: String
        /// Sentence shown when nothing in the window could be rendered.
        public var emptyWindowNotice: String
        /// Heading above an elided oversize record.
        public var oversizeRecordTitle: String
        /// Sentence naming one elided record, given its preformatted size.
        public var oversizeRecordNotice: @Sendable (_ formattedSize: String) -> String
        /// Sentence for the case where the whole window is the tail of one
        /// record that starts before it, so only a lower bound on the size is
        /// known.
        public var oversizeFragmentNotice: @Sendable (_ formattedSize: String) -> String
        /// Sentence shown when Pi branch filtering could not run and every
        /// entry in the window is rendered, so abandoned branches are not
        /// silently presented as the live conversation.
        public var branchUnavailableNotice: String
        public init(
            title: String,
            sessionLabel: String,
            truncationNotice: String,
            emptyWindowNotice: String,
            oversizeRecordTitle: String,
            oversizeRecordNotice: @escaping @Sendable (String) -> String,
            oversizeFragmentNotice: @escaping @Sendable (String) -> String,
            branchUnavailableNotice: String
        ) {
            self.title = title
            self.sessionLabel = sessionLabel
            self.truncationNotice = truncationNotice
            self.emptyWindowNotice = emptyWindowNotice
            self.oversizeRecordTitle = oversizeRecordTitle
            self.oversizeRecordNotice = oversizeRecordNotice
            self.oversizeFragmentNotice = oversizeFragmentNotice
            self.branchUnavailableNotice = branchUnavailableNotice
        }

        /// English copy for this module's own tests, and nothing that ships.
        ///
        /// Deliberately `internal`: the app target is in the same package, so
        /// `package` would still let it reach for this, and "the app layer used
        /// the unlocalized fallback" is a mistake worth a compile error rather
        /// than a review catch. `AwesoMuxCoreTests` reaches it through
        /// `@testable import`.
        static func unlocalizedFallback(agentKind: AgentKind) -> Chrome {
            Chrome(
                title: "\(agentKind.rawValue) transcript",
                sessionLabel: "Session",
                truncationNotice:
                    "Earlier turns are omitted. This document holds the most recent history that fits.",
                emptyWindowNotice:
                    "No conversation turns could be rendered from the most recent history.",
                oversizeRecordTitle: "omitted",
                oversizeRecordNotice: { "One record of \($0) was too large to display." },
                oversizeFragmentNotice: { "One record larger than \($0) could not be displayed." },
                branchUnavailableNotice:
                    "Branch filtering is unavailable for this window — every Pi entry is shown, including any from abandoned turns."
            )
        }
    }

    // MARK: Result

    /// The pure renderer's output. `renderedRecordCount` exists so the reading
    /// wrapper can tell "the window held no conversation" from "the window held
    /// a conversation that fit".
    struct Rendered: Equatable {
        var text: String
        var renderedRecordCount: Int
        var isTruncated: Bool
    }

    // MARK: Reading entry point

    /// Reads the tail of an open transcript and renders it.
    ///
    /// - Parameters:
    ///   - transcript: An open, validated handle from `AgentTranscriptImporter`.
    ///   - chrome: Localized copy for everything awesoMux writes into the
    ///     document. Required, not defaulted — see `Chrome`.
    ///   - budgetBytes: The rendered document's ceiling in UTF-8 bytes.
    /// - Returns: The Markdown document, or why it could not be read.
    public static func render(
        _ transcript: AgentTranscript,
        chrome: Chrome,
        budgetBytes: Int = budgetBytes,
        initialWindowBytes: Int = initialWindowBytes,
        maximumWindowBytes: Int = maximumWindowBytes
    ) -> Result<String, AgentTranscriptUnavailable> {
        guard let provider = AgentTranscriptImporter.Provider(agentKind: transcript.agentKind) else {
            return .failure(.unsupportedAgent(transcript.agentKind))
        }

        let fileSize = Int(clamping: transcript.handle.size)
        let bounds = clampedWindowBounds(initial: initialWindowBytes, ceiling: maximumWindowBytes)
        let ceiling = bounds.ceiling
        var window = bounds.initial
        while true {
            let tail: Data
            let startOffset: UInt64
            let precedingByte: UInt8?
            do {
                (tail, startOffset, precedingByte) = try transcript.handle.readSuffix(
                    maximumBytes: window
                )
            } catch {
                return .failure(.unreadable(error))
            }
            let exhausted = window >= fileSize || window >= ceiling
            let rendered = render(
                jsonlTail: tail,
                provider: provider,
                chrome: chrome,
                sessionID: transcript.sessionID,
                // From the offset actually read, never from the size captured
                // at `open`: a file truncated in between reads short from byte
                // zero, and the stale comparison would drop a whole first
                // record and claim turns were omitted that never existed.
                hasEarlierBytes: startOffset > 0,
                // A window that begins right after a newline begins on a whole
                // record, so there is no leading fragment to drop.
                startsOnRecordBoundary: precedingByte == UInt8(ascii: "\n"),
                // The pure render accounts for what it drops only when there
                // will be no wider window to try.
                isFinalWindow: exhausted,
                budgetBytes: budgetBytes
            )
            if rendered.renderedRecordCount > 0 || exhausted {
                return .success(rendered.text)
            }
            window = min(window * 4, ceiling)
        }
    }

    /// The window bounds the read loop actually uses.
    ///
    /// Both arguments are public and defaulted, so a caller can pass zero — and
    /// a zero window never grows (`0 * 4 == 0`) while `readSuffix(0)` never
    /// renders anything, leaving the loop's exit condition unreachable. The
    /// ceiling is clamped too, and returned, because using the raw argument for
    /// the exhaustion test after clamping the window is the same bug wearing a
    /// hat. Pulled out of `render` so a regression fails a test rather than
    /// hanging one: a synchronous spin cannot be interrupted by a time limit.
    static func clampedWindowBounds(initial: Int, ceiling: Int) -> (initial: Int, ceiling: Int) {
        let ceiling = max(1, ceiling)
        return (min(max(1, initial), ceiling), ceiling)
    }

    // MARK: Pure render

    /// Renders the newest turns in `jsonlTail` that fit inside `budgetBytes`.
    ///
    /// Pure and synchronous: no I/O, no actor, no clock. Records are walked
    /// newest-first and the accumulated result is reversed at the end, so the
    /// window is "as much recent history as fits" rather than a turn count — and
    /// so a full budget truncates at the *start* of the document, on a whole
    /// record boundary, never mid-turn at the end.
    ///
    /// - Parameter startsOnRecordBoundary: Whether the window begins where a
    ///   record does. Only meaningful alongside `hasEarlierBytes`.
    /// - Parameter isFinalWindow: Whether the caller can still widen the window.
    ///   When it cannot, a pass that rendered nothing must say what it dropped
    ///   instead of returning an empty document.
    static func render(
        jsonlTail: Data,
        provider: AgentTranscriptImporter.Provider,
        chrome: Chrome,
        sessionID: String,
        hasEarlierBytes: Bool,
        startsOnRecordBoundary: Bool = false,
        isFinalWindow: Bool,
        budgetBytes: Int
    ) -> Rendered {
        let header = header(chrome: chrome, sessionID: sessionID)
        let truncationNotice = truncationNotice(chrome)
        let emptyWindowNotice = emptyWindowNotice(chrome)
        // Every notice is reserved up front, not charged when emitted: their
        // sizes are known and the budget must survive the worst case where they
        // all appear. Charging them late is how a "check after rendering" loop
        // is reintroduced by accident.
        let reserved =
            header.utf8.count + truncationNotice.utf8.count + emptyWindowNotice.utf8.count
        var remaining = budgetBytes - reserved

        var lines = jsonlTail.split(separator: UInt8(ascii: "\n"))
        // A window that starts mid-file usually starts mid-record, so its first
        // line is a fragment and is dropped. `startsOnRecordBoundary` is the
        // reader's one-byte answer to "did it, though": `Data.split` omits
        // empty subsequences, so a window landing exactly after a newline
        // yields a COMPLETE first record, and dropping it would both lose a
        // renderable turn and report its size as an oversize record that could
        // not be displayed. One extra `pread` is cheaper than that lie.
        // The fragment's length is kept because it is the only evidence left of
        // a record the window could not contain.
        var droppedFragmentBytes: Int?
        if hasEarlierBytes, !startsOnRecordBoundary, !lines.isEmpty {
            droppedFragmentBytes = lines.removeFirst().count
        }

        var chunks: [String] = []
        var isTruncated = hasEarlierBytes
        let piBranch = provider == .pi ? piBranchIndex(in: lines) : nil
        // Fail open, but say so: a window that yields no Pi entry ids — a tail
        // that begins before the newest record with an id, or renamed fields
        // after schema drift — cannot prove branch membership, so every entry
        // is rendered rather than nothing, with one notice instead of the
        // silence that would present abandoned branches as the live
        // conversation. Charged up front like the other notices, so the
        // budget holds whether or not it appears.
        var branchUnavailableNotice: String?
        if provider == .pi, piBranch == nil {
            let notice = italicNotice(chrome.branchUnavailableNotice)
            remaining -= notice.utf8.count
            branchUnavailableNotice = notice
        }
        for index in lines.indices.reversed() {
            let line = lines[index]
            guard !line.isEmpty else { continue }

            let chunk: String
            if line.count > maximumRecordBytes {
                // Measured, not parsed. This branch is the whole reason the
                // budget survives a 57 MB record — and it runs BEFORE the Pi
                // branch filter, because deciding whether an oversized record
                // belongs to the active branch would require decoding it. A Pi
                // record past the cap reports its size like any other
                // provider's, without proof it was on the branch; the marker
                // names a size, not a turn, so the worst case is a reported
                // omission for a record the reader was never going to see.
                chunk = elisionMarker(byteCount: line.count, chrome: chrome)
            } else {
                if let piBranch, !piBranch.isActiveBranchLine(at: index) {
                    continue
                }
                guard let rendered = renderRecord(Data(line), provider: provider) else {
                    continue
                }
                chunk = rendered
            }

            let cost = chunk.utf8.count
            guard cost <= remaining else {
                isTruncated = true
                break
            }
            remaining -= cost
            chunks.append(chunk)
        }

        // A tail that holds nothing but the end of one enormous record renders
        // no turns at all: the fragment is dropped above, and whatever follows
        // it is ignorable. Widening the window is the first answer, but a record
        // bigger than the ceiling cannot be escaped that way — a 57 MB record
        // trailed by 9.3 MiB of `attachment` lines defeats even 64 MiB. On the
        // last pass, name what was dropped. Returning the bare "nothing here"
        // notice would reproduce the blanked scrollback this feature exists to
        // cure, and would do it while a record sat right there, unreported.
        if chunks.isEmpty, isFinalWindow, let droppedFragmentBytes {
            let marker = fragmentElisionMarker(atLeastBytes: droppedFragmentBytes, chrome: chrome)
            if marker.utf8.count <= remaining {
                chunks.append(marker)
            }
        }

        var text = header
        if isTruncated {
            text += truncationNotice
        }
        if let branchUnavailableNotice {
            text += branchUnavailableNotice
        }
        if chunks.isEmpty {
            text += emptyWindowNotice
        }
        text += chunks.reversed().joined()
        return Rendered(text: text, renderedRecordCount: chunks.count, isTruncated: isTruncated)
    }

    // MARK: Document chrome

    /// Chrome copy reaches the document through `inlineSafe`, same as any other
    /// interpolated value: the app supplies it, but a translation is still a
    /// string edited outside this file, and a stray newline or `<` there would
    /// break the heading exactly as content would.
    private static func header(chrome: Chrome, sessionID: String) -> String {
        """
        # \(inlineSafe(chrome.title))

        \(inlineSafe(chrome.sessionLabel)) `\(inlineSafe(sessionID))`


        """
    }

    static func truncationNotice(_ chrome: Chrome) -> String {
        italicNotice(chrome.truncationNotice)
    }

    static func emptyWindowNotice(_ chrome: Chrome) -> String {
        italicNotice(chrome.emptyWindowNotice)
    }

    private static func italicNotice(_ sentence: String) -> String {
        """
        _\(inlineSafe(sentence, limit: 300))_


        """
    }

    /// A record too large to parse still has to be visible: a silent drop looks
    /// exactly like the blanked scrollback the transcript is meant to replace.
    ///
    /// Phrased with a formatted size rather than a raw count so the copy has no
    /// count-dependent noun to pluralize.
    static func elisionMarker(byteCount: Int, chrome: Chrome) -> String {
        marker(chrome: chrome, sentence: chrome.oversizeRecordNotice(formattedSize(byteCount)))
    }

    /// The marker for a record the window only caught the end of, so the size
    /// is a floor rather than a measurement.
    static func fragmentElisionMarker(atLeastBytes: Int, chrome: Chrome) -> String {
        marker(chrome: chrome, sentence: chrome.oversizeFragmentNotice(formattedSize(atLeastBytes)))
    }

    private static func marker(chrome: Chrome, sentence: String) -> String {
        """
        ## \(inlineSafe(chrome.oversizeRecordTitle))

        \(italicNotice(sentence))
        """
    }

    private static func formattedSize(_ byteCount: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    }

    // MARK: Record dispatch

    private static func renderRecord(
        _ data: Data,
        provider: AgentTranscriptImporter.Provider
    ) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
            let record = object as? [String: Any],
            let type = record["type"] as? String
        else { return nil }

        switch provider {
        case .claudeCode: return renderClaudeRecord(record, type: type)
        case .codex: return renderCodexRecord(record, type: type)
        case .pi: return renderPiRecord(record, type: type)
        }
    }

    // MARK: Claude Code

    /// Claude's conversation lives entirely under the top-level `user` and
    /// `assistant` types. Everything else — `attachment` (the most common type
    /// by far), `ai-title`, `queue-operation`, `worktree-state`, and whatever the
    /// next CLI release adds — is skipped rather than switched over, because a
    /// closed switch breaks on a type nobody has seen yet.
    private static func renderClaudeRecord(_ record: [String: Any], type: String) -> String? {
        guard type == "user" || type == "assistant" else { return nil }
        guard let message = record["message"] as? [String: Any] else { return nil }
        // `isSidechain` is true, false, *or* null; only an explicit true marks an
        // inlined subagent turn.
        let isSidechain = (record["isSidechain"] as? Bool) == true

        // `content` is a plain String on ordinary user turns and an array of
        // blocks otherwise. Both shapes occur in the same session, which is why
        // this reads `Any` instead of decoding a typed model that would throw on
        // half of a real transcript.
        if let text = message["content"] as? String {
            return turn(role: type, detail: nil, isSidechain: isSidechain, body: text)
        }
        guard let blocks = message["content"] as? [Any] else { return nil }

        var chunks: [String] = []
        for case let block as [String: Any] in blocks {
            guard let kind = block["type"] as? String else { continue }
            let chunk: String?
            switch kind {
            case "text":
                chunk = turn(
                    role: type,
                    detail: nil,
                    isSidechain: isSidechain,
                    body: block["text"] as? String
                )
            case "thinking":
                chunk = turn(
                    role: type,
                    detail: "thinking",
                    isSidechain: isSidechain,
                    body: block["thinking"] as? String
                )
            case "tool_use":
                chunk = turn(
                    role: type,
                    detail: toolDetail(block["name"]),
                    isSidechain: isSidechain,
                    body: jsonBody(block["input"])
                )
            case "tool_result":
                chunk = turn(
                    role: "tool result",
                    detail: nil,
                    isSidechain: isSidechain,
                    body: plainText(from: block["content"])
                )
            default:
                // Unlike an unknown *record*, an unknown block sits inside a turn
                // that is otherwise being shown, so a silent drop would make the
                // turn misrepresent itself. `image` blocks land here, which also
                // keeps their base64 payload out of the budget.
                chunk = turn(
                    role: type,
                    detail: kind,
                    isSidechain: isSidechain,
                    body: "(not rendered)"
                )
            }
            if let chunk { chunks.append(chunk) }
        }
        return chunks.isEmpty ? nil : chunks.joined()
    }

    // MARK: Codex

    /// Codex records every turn twice: once as `response_item` and again as
    /// `event_msg`. Reading both double-renders the entire conversation, so
    /// `response_item` is the only top-level type read here.
    ///
    /// Note that `agent_message` occurs under *both* top-level types, so a filter
    /// on the payload type alone would not be enough — the top-level gate is.
    private static func renderCodexRecord(_ record: [String: Any], type: String) -> String? {
        guard type == "response_item",
            let payload = record["payload"] as? [String: Any],
            let kind = payload["type"] as? String
        else { return nil }

        switch kind {
        case "message":
            return turn(
                role: payload["role"] as? String ?? "message",
                detail: nil,
                isSidechain: false,
                body: plainText(from: payload["content"])
            )
        case "agent_message":
            return turn(
                role: "assistant",
                detail: payload["author"] as? String,
                isSidechain: false,
                body: plainText(from: payload["content"])
            )
        case "reasoning":
            // `encrypted_content` is opaque ciphertext and is never rendered; the
            // readable part is the summary, with `content` present on some builds.
            let parts = [payload["summary"], payload["content"]].compactMap(plainText(from:))
            return turn(
                role: "assistant",
                detail: "thinking",
                isSidechain: false,
                body: parts.isEmpty ? nil : parts.joined(separator: "\n")
            )
        case "function_call", "custom_tool_call":
            let input = kind == "function_call" ? payload["arguments"] : payload["input"]
            return turn(
                role: "assistant",
                detail: toolDetail(payload["name"]),
                isSidechain: false,
                body: jsonBody(input)
            )
        case "function_call_output", "custom_tool_call_output":
            return turn(
                role: "tool result",
                detail: nil,
                isSidechain: false,
                body: plainText(from: payload["output"]) ?? jsonBody(payload["output"])
            )
        default:
            // `tool_search_call`, `tool_search_output`, `web_search_call`, and
            // every payload type a future release adds.
            return nil
        }
    }

    // MARK: Pi

    /// Pi stores a tree of entries in JSONL. The caller narrows records to the
    /// last entry's parent chain, then this maps each retained conversation row.
    private static func renderPiRecord(_ record: [String: Any], type: String) -> String? {
        switch type {
        case "message":
            guard let message = record["message"] as? [String: Any] else { return nil }
            return turn(
                role: message["role"] as? String ?? "message",
                detail: nil,
                isSidechain: false,
                body: plainText(from: message["content"])
            )
        case "custom_message":
            return turn(
                role: record["role"] as? String ?? "message",
                detail: record["customType"] as? String,
                isSidechain: false,
                body: plainText(from: record["content"])
            )
        default:
            return nil
        }
    }

    /// Pi's JSONL is a tree. The last entry is the active leaf; walking its
    /// parent ids prevents abandoned branches from appearing as if they were
    /// part of the current conversation. A bounded tail may begin mid-branch,
    /// in which case the walk naturally stops at the oldest entry available.
    ///
    /// The index is parsed ONCE and shared with the render loop, so a line is
    /// decoded at most twice (here and in `renderRecord`) instead of three
    /// times, and the loop's membership test is an index lookup rather than a
    /// second parse. Lines past `maximumRecordBytes` never enter the index by
    /// design: they answer by measured length, not by content — see the loop.
    struct PiBranchIndex {
        /// Ids of every parseable, measurable record, in window order.
        var lineIDs: [String?]
        /// The active branch's entry ids.
        var active: Set<String>

        func isActiveBranchLine(at index: Int) -> Bool {
            guard index < lineIDs.count, let id = lineIDs[index] else { return false }
            return active.contains(id)
        }
    }

    private static func piBranchIndex(in lines: [Data.SubSequence]) -> PiBranchIndex? {
        var parents: [String: String?] = [:]
        var leafID: String?
        var lineIDs: [String?] = []
        lineIDs.reserveCapacity(lines.count)
        for line in lines {
            guard line.count <= maximumRecordBytes,
                let object = try? JSONSerialization.jsonObject(with: Data(line)),
                let record = object as? [String: Any],
                let id = record["id"] as? String
            else {
                lineIDs.append(nil)
                continue
            }
            parents[id] = record["parentId"] as? String
            leafID = id
            lineIDs.append(id)
        }
        guard var current = leafID else { return nil }
        var branch: Set<String> = []
        while branch.insert(current).inserted,
            let parent = parents[current] ?? nil
        {
            current = parent
        }
        return PiBranchIndex(lineIDs: lineIDs, active: branch)
    }

    // MARK: Turn formatting

    /// One role header followed by one fenced block holding the content.
    ///
    /// The header stays outside the container and the content stays inside it.
    /// Nothing crosses: the header's only content-derived part is `detail`, which
    /// is sanitized, and the body cannot escape a fence sized to exceed its own
    /// longest backtick run.
    private static func turn(
        role: String,
        detail: String?,
        isSidechain: Bool,
        body: String?
    ) -> String? {
        guard var body, !body.isEmpty else { return nil }
        while body.last?.isNewline == true {
            body.removeLast()
        }
        guard !body.isEmpty else { return nil }

        var header = "## \(inlineSafe(role))"
        if let detail = detail.map({ inlineSafe($0) }), !detail.isEmpty {
            header += " · \(detail)"
        }
        if isSidechain {
            header += " · subagent"
        }
        let fence = String(repeating: "`", count: fenceLength(for: body))
        return "\(header)\n\n\(fence)text\n\(body)\n\(fence)\n\n"
    }

    /// The fence length CommonMark requires to contain `body`: one backtick more
    /// than its longest run, never fewer than three.
    ///
    /// A closing fence is a line of at least as many backticks as the opener, so
    /// exceeding the longest run anywhere in the content makes a content-borne
    /// close impossible — including the mid-line runs that could not have closed
    /// a fence anyway, counted here because the cheap answer is the safe one.
    static func fenceLength(for body: String) -> Int {
        var longest = 0
        var current = 0
        for byte in body.utf8 {
            if byte == UInt8(ascii: "`") {
                current += 1
                longest = max(longest, current)
            } else {
                current = 0
            }
        }
        return max(3, longest + 1)
    }

    /// Strips everything a content-derived string could use against the one
    /// place transcript text is emitted outside a fence — a heading line.
    ///
    /// Newlines end the block. `<` and `>` open the HTML block that
    /// `AttributedMarkdownBuilder` reads annotation markers out of, and the
    /// autolink syntax. Backticks would interact with fence counting. `[` and
    /// `]` are link and image syntax: swift-markdown parses inline content
    /// inside ATX headings, so a `tool_use` named
    /// `[Approve this change](https://evil.example/pwn)` would otherwise render
    /// as a genuine clickable link under awesoMux's own chrome — and a
    /// transcript is read-only, which gates the `.document` open branch but not
    /// the `.external` one.
    ///
    /// Removal, not escaping: a mangled-but-inert tool name is the cheap answer,
    /// and nothing downstream needs the original characters back.
    static func inlineSafe(_ value: String, limit: Int = 120) -> String {
        var result = ""
        result.reserveCapacity(min(value.count, limit))
        var truncated = false
        for character in value {
            guard result.count < limit else {
                truncated = true
                break
            }
            if character.isNewline || Self.inlineUnsafeCharacters.contains(character) {
                continue
            }
            result.append(character)
        }
        return truncated ? result + "…" : result
    }

    private static let inlineUnsafeCharacters: Set<Character> = ["<", ">", "`", "[", "]"]

    private static func toolDetail(_ name: Any?) -> String? {
        guard let name = name as? String, !name.isEmpty else { return nil }
        return "tool \(name)"
    }

    // MARK: Content extraction

    /// Flattens the several shapes a content field takes into plain text.
    ///
    /// A plain String passes through. An array yields the `text` of every element
    /// that has one, which covers Claude's `text` blocks and Codex's
    /// `input_text` / `output_text` / `summary_text` uniformly. Elements without
    /// a `text` — Claude's `tool_reference` and `image` — contribute nothing,
    /// which is also what keeps base64 image payloads out of the budget.
    private static func plainText(from content: Any?) -> String? {
        if let text = content as? String { return text }
        guard let items = content as? [Any] else { return nil }
        var parts: [String] = []
        for case let item as [String: Any] in items {
            if let text = item["text"] as? String, !text.isEmpty {
                parts.append(text)
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    /// Tool arguments, which arrive as a JSON string on Codex and a decoded
    /// object on Claude.
    ///
    /// Deliberately compact rather than pretty-printed: indentation can multiply
    /// a record's byte count several times over, and keeping the rendered size at
    /// or below the source size is what makes `maximumRecordBytes` a real
    /// guarantee that the newest record always fits the budget.
    private static func jsonBody(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        guard let value, JSONSerialization.isValidJSONObject(value),
            let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
