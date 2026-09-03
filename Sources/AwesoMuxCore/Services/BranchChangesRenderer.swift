import Foundation
import UnicodeHygiene

/// Turns a `git diff` into a bounded Markdown document.
///
/// Three things shape every decision here, and they are the same three that
/// shape `AgentTranscriptRenderer` — read that type's preamble first; this one
/// records only what differs.
///
/// **The byte budget is the feature.** `DocumentURLValidator.maxFileSizeBytes`
/// *rejects* an oversize document rather than truncating it, so a renderer that
/// overshoots shows the user an error where the diff should be. The input is
/// already capped by the command runner, but the cap is on *input* bytes: a
/// diff of a binary-ish file replaces each invalid UTF-8 byte with a three-byte
/// U+FFFD, so 1 MiB in can be 3 MiB out. The budget is therefore enforced on
/// the rendered output, after sanitization.
///
/// **A truncated diff must say so, twice.** A diff that silently stops halfway
/// is worse than one that refuses, because the reader cannot tell "no more
/// changes" from "the rest was cut" — and a reader who scrolled straight to the
/// bottom never saw a notice placed only at the top. So the notice appears both
/// above the opening fence and below the closing one, and the body is always
/// cut back to a whole line so the document never ends mid-hunk.
///
/// **The diff is plain text in fences, not rich Markdown.** File paths and
/// hunk bodies are untrusted text that routinely contain their own code fences
/// and literal `<!-- AMX … -->` markers, which `AttributedMarkdownBuilder`
/// parses as real annotations. Each file's hunks therefore go inside a fence
/// sized to contain them, and nothing content-derived reaches the document
/// outside a fence without passing through `inlineSafe(_:)` (headings) or
/// `inlineCode(_:)` (everything else) first. A heading path is plain text
/// rather than a code span so it keeps its heading size, which leaves it
/// eligible for the document view's bare-path autolinking; that pass is off
/// for read-only documents, which every rendered diff is.
///
/// **One section per file.** git's own per-file header (`diff --git`, `index`,
/// `---`/`+++`, the rename and new/deleted lines) is four to six lines of
/// bookkeeping a reader scans past to find the path; the section heading names
/// the path and its status instead, and only the hunks stay in the fence. The
/// split is on `diff --git ` at column zero, which hunk content can never
/// produce: every line inside a hunk carries a space, `+`, or `-` prefix.
public enum BranchChangesRenderer {

    // MARK: Budgets

    /// The rendered document's hard ceiling, at three quarters of the viewer's
    /// own cap. Derived rather than restated so the two can never drift, and the
    /// remaining quarter is headroom the arithmetic below never has to reason
    /// about precisely.
    public static let budgetBytes = DocumentURLValidator.maxFileSizeBytes * 3 / 4

    /// The longest backtick run the body may contain.
    ///
    /// A fence has to be one backtick longer than the longest run inside it, so
    /// an unbounded run makes the fence itself an unbounded cost that the budget
    /// cannot reserve for. Cutting the body at the line where such a run starts
    /// keeps the fence a fixed, budgetable 64 bytes, and reports the result
    /// through the truncation notice that already exists — the same answer the
    /// byte budget gives, for the same reason. No real diff comes close.
    static let maximumBacktickRun = 63

    /// Reserved for the two fences and their surrounding newlines. `+ 1` is the
    /// fence's own excess over `maximumBacktickRun`; the constant covers the
    /// info string and the blank lines around both fences.
    private static let fenceReserveBytes = 2 * (maximumBacktickRun + 1) + 16

    // MARK: Chrome

    /// The document's own words — everything in the rendered file that awesoMux
    /// wrote rather than git.
    ///
    /// It is an input so that every user-facing sentence is composed in the
    /// layer that owns copy (ADR-0014) and this renderer stays a pure function
    /// of its arguments, testable without a bundle or a locale. Markdown
    /// structure stays here — these are sentences, not templates, so a
    /// translation can never alter the document's shape.
    public struct Chrome: Sendable {
        /// One sentence naming the comparison, given the base ref and the
        /// repository name already wrapped as Markdown code spans, e.g.
        /// "Compared with `origin/main` in `awesomux`."
        public var comparisonNotice: @Sendable (_ base: String, _ repository: String) -> String
        /// One sentence naming when this snapshot was taken and how to refresh
        /// it. Preformatted by the caller, which owns date formatting.
        public var snapshotNotice: String
        /// One sentence stating that untracked files are not in the diff — a
        /// reader who just created a file and sees it missing would otherwise
        /// reasonably conclude the diff is broken.
        public var untrackedNotice: String
        /// Sentence shown above the first section AND at the end when the diff
        /// is cut short.
        public var truncationNotice: String
        /// Sentence shown instead of any section when the branch and its base
        /// agree, given the sanitized base ref to name in it.
        public var emptyNotice: @Sendable (_ base: String) -> String
        /// Suffix on a file heading for a file the branch created, e.g. "new file".
        public var newFileLabel: String
        /// Suffix on a file heading for a file the branch deleted, e.g. "deleted".
        public var deletedFileLabel: String
        /// Suffix on a file heading for a renamed file, given the previous
        /// path, e.g. "renamed from old/path".
        public var renamedFromLabel: @Sendable (_ previousPath: String) -> String

        public init(
            comparisonNotice: @escaping @Sendable (String, String) -> String,
            snapshotNotice: String,
            untrackedNotice: String,
            truncationNotice: String,
            emptyNotice: @escaping @Sendable (String) -> String,
            newFileLabel: String,
            deletedFileLabel: String,
            renamedFromLabel: @escaping @Sendable (String) -> String
        ) {
            self.comparisonNotice = comparisonNotice
            self.snapshotNotice = snapshotNotice
            self.untrackedNotice = untrackedNotice
            self.truncationNotice = truncationNotice
            self.emptyNotice = emptyNotice
            self.newFileLabel = newFileLabel
            self.deletedFileLabel = deletedFileLabel
            self.renamedFromLabel = renamedFromLabel
        }

        /// English copy for this module's own tests, and nothing that ships.
        ///
        /// Deliberately `internal`: the app target is in the same package, so
        /// `package` would still let it reach for this, and "the app layer used
        /// the unlocalized fallback" is a mistake worth a compile error rather
        /// than a review catch.
        static var unlocalizedFallback: Chrome {
            Chrome(
                comparisonNotice: { "Compared with \($0) in \($1)." },
                snapshotNotice:
                    "Snapshot taken just now. Run Show Branch Changes again to refresh it.",
                untrackedNotice: "Untracked files are not included.",
                truncationNotice: "This diff is incomplete.",
                emptyNotice: { "This branch matches \($0). There is nothing to show." },
                newFileLabel: "new file",
                deletedFileLabel: "deleted",
                renamedFromLabel: { "renamed from \($0)" }
            )
        }
    }

    // MARK: Render

    /// Renders `diff` as a bounded Markdown document.
    ///
    /// - Parameters:
    ///   - diff: Raw `git diff` stdout. Not required to be valid UTF-8.
    ///   - identity: The comparison's provenance. Taken whole rather than as
    ///     three loose strings so the document header names the branch, base,
    ///     and repository through the very accessors the tab title uses — the
    ///     header is the same untrusted repository metadata in the same app
    ///     chrome, and a second spelling of "how a ref is displayed" is a second
    ///     place for the `UnicodeHygiene` pass to be forgotten.
    ///   - isTruncated: Whether the runner already cut the diff at its output
    ///     cap. Independent of the budget — either alone means incomplete.
    ///   - chrome: Localized copy. Required, not defaulted — see `Chrome`.
    public static func render(
        diff: Data,
        identity: BranchChangesIdentity,
        isTruncated: Bool,
        chrome: Chrome,
        budgetBytes: Int = budgetBytes
    ) -> String {
        let sanitized = sanitizedBody(diff)
        var truncated = isTruncated || sanitized.wasCut

        // An upstream cut lands mid-line; a notice saying "this diff is
        // incomplete" does not make a half-line honest as a line, so it goes.
        // A cut that landed on a newline keeps its last line, because
        // `wholeLines` cuts after the final newline rather than before it. The
        // cut stays conditional because a *complete* diff's last line may
        // legitimately have no trailing newline.
        let bytes = truncated ? wholeLines(sanitized.bytes[...]) : sanitized.bytes
        let sections = FileSection.parse(String(decoding: bytes, as: UTF8.self))

        let header = header(chrome: chrome, identity: identity)
        let notice = boldNotice(chrome.truncationNotice)
        // Both notices are reserved up front, not charged when emitted: their
        // size is known and the budget must survive the case where they appear.
        var remaining = budgetBytes - header.utf8.count - 2 * notice.utf8.count

        var body = ""
        for section in sections {
            var rendered = ""
            var rest = remaining
            if let heading = section.heading(chrome: chrome) {
                rendered += "## \(heading)\n\n"
                rest -= rendered.utf8.count
            }
            var lines = ""
            var lineCount = 0
            if !section.lines.isEmpty {
                rest -= fenceReserveBytes
                for line in section.lines {
                    let cost = line.utf8.count + 1
                    guard cost <= rest else { break }
                    lines += line
                    lines += "\n"
                    rest -= cost
                    lineCount += 1
                }
                // The fence is sized for what was kept; the reserve covers it
                // because the sanitizer capped every run below `maximumBacktickRun`.
                let fence = String(repeating: "`", count: fenceLength(for: Array(lines.utf8)))
                rendered += "\(fence)diff\n\(lines)\(fence)\n\n"
            }
            let cut = lineCount < section.lines.count
            // A section that kept no change line is dropped whole rather than
            // shown as a heading over an empty fence, or over a lone `@@` line
            // whose enormous first hunk line did not fit: either would claim a
            // file changed while showing nothing of how.
            let keptAChangeLine = section.lines.prefix(lineCount).contains { !$0.hasPrefix("@@") }
            if rest < 0 || (cut && !keptAChangeLine) {
                truncated = true
                break
            }
            body += rendered
            remaining = rest
            if cut {
                truncated = true
                break
            }
        }

        var text = header
        // An empty diff is an answer, not a failure: the branch agrees with its
        // base. Only say so when nothing was cut, or the sentence would claim
        // agreement the renderer never established.
        if body.isEmpty, !truncated {
            text += italicNotice(chrome.emptyNotice(inlineSafe(identity.displayBaseRef)))
            return text
        }
        if truncated {
            text += notice
        }
        text += body
        // The closing notice brackets the body; with nothing to bracket it
        // would only repeat the opening one.
        if truncated, !body.isEmpty {
            text += notice
        }
        return text
    }

    // MARK: File sections

    /// One file's entry in the diff: what git said about it in the header
    /// lines, and the hunk lines that follow.
    struct FileSection: Equatable {
        /// Displayed path, from `+++ b/` (or `--- a/` for a deletion, or the
        /// `diff --git` line when neither is present). Nil for lines that
        /// precede any `diff --git` line, such as `* Unmerged path`.
        var path: String?
        var previousPath: String?
        var isNew = false
        var isDeleted = false
        /// Everything that was not consumed into the heading, in order and
        /// without trailing newlines — hunks, but also `Binary files … differ`
        /// and `old mode`/`new mode`, which stay visible rather than growing
        /// their own copy.
        var lines: [Substring] = []

        /// Splits a sanitized diff on `diff --git ` at column zero.
        static func parse(_ text: String) -> [FileSection] {
            var sections: [FileSection] = []
            var current = FileSection()
            var started = false
            var inHeader = false
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                if line.hasPrefix("diff --git ") {
                    if started { sections.append(current) }
                    current = FileSection(path: gitLinePath(line))
                    started = true
                    inHeader = true
                    continue
                }
                started = true
                if inHeader {
                    switch current.consumeHeaderLine(line) {
                    case .consumed:
                        continue
                    case .preserved:
                        current.lines.append(line)
                        continue
                    case .ended:
                        inHeader = false
                    }
                }
                current.lines.append(line)
            }
            if started { sections.append(current) }
            // `split` with omittingEmptySubsequences: false yields one trailing
            // empty line for a body that ends in a newline; drop it. A body
            // that legitimately ends without a newline keeps its last line.
            if !sections.isEmpty, sections[sections.count - 1].lines.last == "" {
                sections[sections.count - 1].lines.removeLast()
            }
            return sections.filter { $0.path != nil || !$0.lines.isEmpty }
        }

        enum HeaderLine {
            /// Folded into the heading; not shown.
            case consumed
            /// Header vocabulary the reader should still see (`old mode`/`new
            /// mode`): kept in the body, and the header continues after it,
            /// because git prints `index` and `---`/`+++` below the mode lines.
            case preserved
            /// The first body line — a hunk, `Binary files … differ`, or
            /// anything unexpected, which stays visible.
            case ended
        }

        /// Absorbs one line of git's per-file header into this section's fields.
        private mutating func consumeHeaderLine(_ line: Substring) -> HeaderLine {
            if line.hasPrefix("index ") || line.hasPrefix("similarity index ")
                || line.hasPrefix("dissimilarity index ") || line.hasPrefix("copy from ")
            {
                return .consumed
            }
            if line.hasPrefix("old mode ") || line.hasPrefix("new mode ") {
                return .preserved
            }
            if line.hasPrefix("new file mode ") {
                isNew = true
                return .consumed
            }
            if line.hasPrefix("deleted file mode ") {
                isDeleted = true
                return .consumed
            }
            if line.hasPrefix("rename from ") {
                previousPath = Self.unquoted(line.dropFirst("rename from ".count))
                return .consumed
            }
            if line.hasPrefix("rename to ") {
                path = Self.unquoted(line.dropFirst("rename to ".count))
                return .consumed
            }
            if line.hasPrefix("copy to ") {
                path = Self.unquoted(line.dropFirst("copy to ".count))
                return .consumed
            }
            if line.hasPrefix("--- ") {
                if !isNew, let stripped = Self.strippingPrefix(line.dropFirst(4)), path == nil || isDeleted {
                    path = stripped
                }
                return .consumed
            }
            if line.hasPrefix("+++ ") {
                if let stripped = Self.strippingPrefix(line.dropFirst(4)) {
                    path = stripped
                }
                return .consumed
            }
            return .ended
        }

        /// git (with the default `core.quotepath`) prints a path holding any
        /// non-ASCII or control byte as a C string — `"caf\303\251.txt"` for
        /// `café.txt` — and appends a tab after a path containing spaces. The
        /// tab and quotes go, and the escapes decode back to the path, which
        /// then passes through the same scalar hygiene the body had: the bytes
        /// were escaped when the sanitizer ran, so a bidi override smuggled as
        /// octal would otherwise arrive unseen.
        private static func unquoted(_ value: Substring) -> String {
            var value = value
            while value.hasSuffix("\t") { value = value.dropLast() }
            guard value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 else {
                return String(value)
            }
            var bytes: [UInt8] = []
            var scalars = value.dropFirst().dropLast().unicodeScalars.makeIterator()
            while let scalar = scalars.next() {
                guard scalar == "\\" else {
                    bytes.append(contentsOf: String(scalar).utf8)
                    continue
                }
                guard let escaped = scalars.next() else { break }
                switch escaped {
                case "a": bytes.append(0x07)
                case "b": bytes.append(0x08)
                case "f": bytes.append(0x0C)
                case "n": bytes.append(0x0A)
                case "r": bytes.append(0x0D)
                case "t": bytes.append(0x09)
                case "v": bytes.append(0x0B)
                case "0"..."7":
                    var octal = escaped.value - 0x30
                    var digits = 1
                    while digits < 3, let peek = scalars.next() {
                        if ("0"..."7").contains(peek) {
                            octal = octal * 8 + (peek.value - 0x30)
                            digits += 1
                        } else {
                            bytes.append(UInt8(truncatingIfNeeded: octal))
                            octal = UInt32.max
                            bytes.append(contentsOf: String(peek).utf8)
                            break
                        }
                    }
                    if octal != UInt32.max { bytes.append(UInt8(truncatingIfNeeded: octal)) }
                default:
                    // `\\` and `\"`, and anything git never emits.
                    bytes.append(contentsOf: String(escaped).utf8)
                }
            }
            let sanitized = sanitizedBody(Data(bytes))
            return String(decoding: sanitized.bytes, as: UTF8.self)
        }

        /// `a/path` or `b/path` → `path`; `/dev/null` → nil.
        private static func strippingPrefix(_ value: Substring) -> String? {
            if value == "/dev/null" { return nil }
            let value = unquoted(value)
            if value.hasPrefix("a/") || value.hasPrefix("b/") {
                return String(value.dropFirst(2))
            }
            return value
        }

        /// The path from `diff --git a/X b/X`, the only header line a binary
        /// or mode-only entry carries. Two copies of the same path are the
        /// common case and split exactly, quoted or not; differing paths (a
        /// rename or copy) resolve to the `b/` side, which `rename to` or
        /// `copy to` then confirms.
        private static func gitLinePath(_ line: Substring) -> String {
            let rest = line.dropFirst("diff --git ".count)
            if rest.hasPrefix("\""), let boundary = rest.range(of: "\" ") {
                let first = strippingPrefix(rest[..<boundary.lowerBound]) ?? ""
                let second = strippingPrefix(rest[boundary.upperBound...]) ?? ""
                return second.isEmpty ? first : second
            }
            let count = rest.count
            if count >= 5, (count - 5) % 2 == 0 {
                let length = (count - 5) / 2
                let candidate = rest.dropFirst(2).prefix(length)
                if rest == "a/\(candidate) b/\(candidate)" {
                    return String(candidate)
                }
            }
            return String(rest)
        }

        /// The section heading's Markdown, or nil for a headingless run of
        /// lines that preceded any file.
        ///
        /// Plain text, not a code span: the document view sizes a monospaced
        /// run at body size even inside a heading, so a code-span path would
        /// vanish into the hunks it is meant to label. Backticks stay so a path
        /// reads as itself; a pair of them is at worst an inline code span.
        func heading(chrome: Chrome) -> String? {
            guard let path else { return nil }
            var heading = headingText(path)
            let status: String?
            if isNew {
                status = chrome.newFileLabel
            } else if isDeleted {
                status = chrome.deletedFileLabel
            } else if let previousPath, previousPath != path {
                status = chrome.renamedFromLabel(headingText(previousPath))
            } else {
                status = nil
            }
            if let status {
                heading += " — _\(inlineSafe(status, limit: 400, allowingBackticks: true))_"
            }
            return heading
        }
    }

    // MARK: Document chrome

    /// Chrome copy reaches the document through `inlineSafe`, same as any other
    /// interpolated value: the app supplies it, but a translation is still a
    /// string edited outside this file, and a stray newline or `<` there would
    /// break the heading exactly as content would.
    ///
    /// The repository's own names reach it through the identity's display
    /// accessors first, so they arrive `UnicodeHygiene`-sanitized — `inlineCode`
    /// defends the Markdown grammar and nothing else, and a bidi override or a
    /// run of zero-width scalars in a branch name passes through it untouched.
    ///
    /// The heading is the branch itself: the tab title already says this is a
    /// diff and names the base and repository, so a "Branch changes" title
    /// above it would say nothing the reader has not just read.
    private static func header(chrome: Chrome, identity: BranchChangesIdentity) -> String {
        let comparison = chrome.comparisonNotice(
            inlineCode(identity.displayBaseRef),
            inlineCode(identity.displayRepositoryName)
        )
        return """
            # \(headingText(identity.displayBranch))

            \(inlineSafe(comparison, limit: 1000, allowingBackticks: true))

            \(italicNotice(chrome.snapshotNotice + " " + chrome.untrackedNotice))
            """
    }

    /// Content-derived text for a heading: `inlineSafe` for the grammar it
    /// strips, then a backslash before every remaining Markdown punctuation
    /// mark so the text reads as itself. A backtick in one path and another in
    /// the rename status would otherwise pair into a code span that swallows
    /// the words between them; a `*` pair italicizes part of a filename; a
    /// trailing `#` closes the heading early. Escaping rather than stripping
    /// because a path is an identifier, and `my_file` is not `myfile`.
    static func headingText(_ value: String) -> String {
        var result = ""
        for character in inlineSafe(value, limit: 300, allowingBackticks: true) {
            if Self.headingEscapedCharacters.contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }

    private static let headingEscapedCharacters: Set<Character> = ["\\", "`", "*", "_", "#", "~"]

    private static func italicNotice(_ sentence: String) -> String {
        """
        _\(inlineSafe(sentence, limit: 300))_


        """
    }

    static func boldNotice(_ sentence: String) -> String {
        """
        **\(inlineSafe(sentence, limit: 300))**


        """
    }

    // MARK: Body sanitization

    struct SanitizedBody {
        var bytes: [UInt8]
        /// Whether a backtick run past `maximumBacktickRun` forced an early cut.
        var wasCut: Bool
    }

    /// Decodes `diff` as UTF-8 (replacing invalid bytes), removes terminal
    /// controls, and renders direction-changing or invisible Unicode as an
    /// explicit `<U+XXXX>` token. A review surface must not let Trojan Source
    /// controls make displayed code differ from the bytes under review.
    ///
    /// Carriage returns are dropped rather than kept, so a CRLF file's diff does
    /// not render every line with a trailing control byte.
    static func sanitizedBody(_ diff: Data) -> SanitizedBody {
        let decoded = String(decoding: diff, as: UTF8.self)
        var kept: [UInt8] = []
        kept.reserveCapacity(decoded.utf8.count)
        var backtickRun = 0
        var lastLineStart = 0
        func append(_ byte: UInt8) -> Bool {
            kept.append(byte)
            if byte == UInt8(ascii: "\n") {
                backtickRun = 0
                lastLineStart = kept.count
                return true
            }
            if byte == UInt8(ascii: "`") {
                backtickRun += 1
                if backtickRun > maximumBacktickRun {
                    // Cut at the start of the offending line, so the document
                    // never ends inside a run the fence could not contain.
                    kept.removeSubrange(lastLineStart...)
                    return false
                }
            } else {
                backtickRun = 0
            }
            return true
        }

        for scalar in decoded.unicodeScalars {
            let value = scalar.value
            if value == 0x0A || value == 0x09 {
                guard append(UInt8(value)) else {
                    return SanitizedBody(bytes: kept, wasCut: true)
                }
                continue
            }
            // Load-bearing that controls are removed before counting backticks:
            // stripping one between two runs joins those runs in the output.
            if value <= 0x1F || value == 0x7F || 0x80...0x9F ~= value {
                continue
            }
            let rendered: String
            if UnicodeHygiene.isUnsafePathScalar(scalar) {
                rendered = String(format: "<U+%04X>", value)
            } else {
                rendered = String(scalar)
            }
            for byte in rendered.utf8 {
                guard append(byte) else {
                    return SanitizedBody(bytes: kept, wasCut: true)
                }
            }
        }
        return SanitizedBody(bytes: kept, wasCut: false)
    }

    /// Cuts `bytes` back to the last complete line, so a budget that lands
    /// mid-hunk never presents half a line as a whole one. Returns empty when
    /// the prefix holds no newline at all — a single line longer than the whole
    /// budget is not a line the document can honestly show part of.
    ///
    /// Also the reason the cut is always UTF-8 safe: the input is valid UTF-8
    /// and the cut lands immediately after an ASCII newline.
    static func wholeLines(_ bytes: ArraySlice<UInt8>) -> [UInt8] {
        guard let lastNewline = bytes.lastIndex(of: UInt8(ascii: "\n")) else { return [] }
        return Array(bytes[bytes.startIndex...lastNewline])
    }

    // MARK: Inline safety

    /// The fence length CommonMark requires to contain `body`: one backtick more
    /// than its longest run, never fewer than three.
    ///
    /// A closing fence is a line of at least as many backticks as the opener, so
    /// exceeding the longest run anywhere in the content makes a content-borne
    /// close impossible — including the mid-line runs that could not have closed
    /// a fence anyway, counted here because the cheap answer is the safe one.
    static func fenceLength(for body: [UInt8]) -> Int {
        max(3, longestBacktickRun(in: body) + 1)
    }

    static func longestBacktickRun(in bytes: [UInt8]) -> Int {
        var longest = 0
        var current = 0
        for byte in bytes {
            if byte == UInt8(ascii: "`") {
                current += 1
                longest = max(longest, current)
            } else {
                current = 0
            }
        }
        return longest
    }

    /// A CommonMark code span that contains `value` verbatim.
    ///
    /// Run-aware rather than backtick-stripping: git permits a backtick in a
    /// branch name, and a branch called ``fix-`quoting` `` should read as
    /// itself rather than as `fix-quoting`. The delimiter is one backtick longer
    /// than the longest run inside, and the content is space-padded when it
    /// starts or ends with a backtick, which is exactly the pair of rules
    /// CommonMark states for a code span that can hold arbitrary backticks.
    static func inlineCode(_ value: String) -> String {
        let content = inlineSafe(value, allowingBackticks: true)
        guard !content.isEmpty else { return "" }
        let delimiter = String(
            repeating: "`",
            count: longestBacktickRun(in: Array(content.utf8)) + 1
        )
        let padding = content.hasPrefix("`") || content.hasSuffix("`") ? " " : ""
        return "\(delimiter)\(padding)\(content)\(padding)\(delimiter)"
    }

    /// Strips everything a content-derived string could use against the places
    /// text is emitted outside a fence — a heading, a label line, a notice.
    ///
    /// Newlines end the block. `<` and `>` open the HTML block that
    /// `AttributedMarkdownBuilder` reads annotation markers out of, and the
    /// autolink syntax. `[` and `]` are link and image syntax: swift-markdown
    /// parses inline content inside headings and paragraphs, so a branch named
    /// `[Approve this change](https://evil.example/pwn)` would otherwise render
    /// as a genuine clickable link under awesoMux's own chrome. Backticks are
    /// stripped too, except for the code-span path that sizes its own delimiter
    /// around them.
    ///
    /// Removal, not escaping: a mangled-but-inert label is the cheap answer, and
    /// nothing downstream needs the original characters back.
    static func inlineSafe(_ value: String, limit: Int = 120, allowingBackticks: Bool = false) -> String {
        var result = ""
        result.reserveCapacity(min(value.count, limit))
        var truncated = false
        for character in value {
            guard result.count < limit else {
                truncated = true
                break
            }
            if character.isNewline { continue }
            if character == "`" {
                if allowingBackticks { result.append(character) }
                continue
            }
            if Self.inlineUnsafeCharacters.contains(character) { continue }
            result.append(character)
        }
        return truncated ? result + "…" : result
    }

    private static let inlineUnsafeCharacters: Set<Character> = ["<", ">", "[", "]"]
}
