import Foundation

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
/// **The diff is plain text in a fence, not rich Markdown.** File paths and
/// hunk bodies are untrusted text that routinely contain their own code fences
/// and literal `<!-- AMX … -->` markers, which `AttributedMarkdownBuilder`
/// parses as real annotations. The body therefore goes inside a fence sized to
/// contain it, and nothing content-derived reaches the document outside a fence
/// without passing through `inlineCode(_:)` first.
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
        /// Level-1 heading, e.g. "Branch changes".
        public var title: String
        /// Label before the branch name, e.g. "Branch".
        public var branchLabel: String
        /// Label before the base ref, e.g. "Compared with".
        public var baseLabel: String
        /// Label before the repository name, e.g. "Repository".
        public var repositoryLabel: String
        /// One sentence naming when this snapshot was taken and how to refresh
        /// it. Preformatted by the caller, which owns date formatting.
        public var snapshotNotice: String
        /// One sentence stating that untracked files are not in the diff — a
        /// reader who just created a file and sees it missing would otherwise
        /// reasonably conclude the diff is broken.
        public var untrackedNotice: String
        /// Sentence shown above AND below the fence when the diff is cut short.
        public var truncationNotice: String
        /// Sentence shown instead of a fence when the branch and its base
        /// agree, given the sanitized base ref to name in it.
        public var emptyNotice: @Sendable (_ base: String) -> String

        public init(
            title: String,
            branchLabel: String,
            baseLabel: String,
            repositoryLabel: String,
            snapshotNotice: String,
            untrackedNotice: String,
            truncationNotice: String,
            emptyNotice: @escaping @Sendable (String) -> String
        ) {
            self.title = title
            self.branchLabel = branchLabel
            self.baseLabel = baseLabel
            self.repositoryLabel = repositoryLabel
            self.snapshotNotice = snapshotNotice
            self.untrackedNotice = untrackedNotice
            self.truncationNotice = truncationNotice
            self.emptyNotice = emptyNotice
        }

        /// English copy for this module's own tests, and nothing that ships.
        ///
        /// Deliberately `internal`: the app target is in the same package, so
        /// `package` would still let it reach for this, and "the app layer used
        /// the unlocalized fallback" is a mistake worth a compile error rather
        /// than a review catch.
        static var unlocalizedFallback: Chrome {
            Chrome(
                title: "Branch changes",
                branchLabel: "Branch",
                baseLabel: "Compared with",
                repositoryLabel: "Repository",
                snapshotNotice:
                    "Snapshot taken just now. Run Show Branch Changes again to refresh it.",
                untrackedNotice: "Untracked files are not included.",
                truncationNotice: "This diff is incomplete.",
                emptyNotice: { "This branch matches \($0). There is nothing to show." }
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

        let header = header(chrome: chrome, identity: identity)
        let notice = boldNotice(chrome.truncationNotice)
        // Both notices are reserved up front, not charged when emitted: their
        // size is known and the budget must survive the case where they appear.
        // Charging them late is how a "check after rendering" loop is
        // reintroduced by accident.
        let reserved = header.utf8.count + 2 * notice.utf8.count + fenceReserveBytes
        let available = max(0, budgetBytes - reserved)

        // Cut back to a whole line only when the budget actually bites. A diff
        // whose last line has no trailing newline is complete, and dropping it
        // unconditionally would silently lose a real hunk line.
        let body: [UInt8]
        if sanitized.bytes.count > available {
            truncated = true
            body = wholeLines(sanitized.bytes.prefix(available))
        } else {
            body = sanitized.bytes
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
        let fence = String(repeating: "`", count: fenceLength(for: body))
        let bodyText = String(decoding: body, as: UTF8.self)
        // The closing fence has to start its own line.
        let terminator = bodyText.isEmpty || bodyText.hasSuffix("\n") ? "" : "\n"
        text += "\(fence)diff\n\(bodyText)\(terminator)\(fence)\n"
        if truncated {
            text += "\n" + notice
        }
        return text
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
    private static func header(chrome: Chrome, identity: BranchChangesIdentity) -> String {
        """
        # \(inlineSafe(chrome.title))

        \(inlineSafe(chrome.branchLabel)) \(inlineCode(identity.displayBranch))

        \(inlineSafe(chrome.baseLabel)) \(inlineCode(identity.displayBaseRef))

        \(inlineSafe(chrome.repositoryLabel)) \(inlineCode(identity.displayRepositoryName))

        \(italicNotice(chrome.snapshotNotice))\(italicNotice(chrome.untrackedNotice))
        """
    }

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

    /// Decodes `diff` as UTF-8 (replacing invalid bytes) and removes everything
    /// that has no business in a fenced block: C0 controls other than newline
    /// and tab — ESC included, which is what keeps a diff of a file full of
    /// terminal escapes from repainting the pane's own rendering — and DEL.
    ///
    /// Carriage returns are dropped rather than kept, so a CRLF file's diff does
    /// not render every line with a trailing control byte.
    static func sanitizedBody(_ diff: Data) -> SanitizedBody {
        let decoded = Array(String(decoding: diff, as: UTF8.self).utf8)
        var kept: [UInt8] = []
        kept.reserveCapacity(decoded.count)
        var backtickRun = 0
        var lastLineStart = 0
        for byte in decoded {
            if byte == UInt8(ascii: "\n") {
                kept.append(byte)
                backtickRun = 0
                lastLineStart = kept.count
                continue
            }
            // Load-bearing that the run is counted over what is KEPT, not over
            // the input: dropping a control byte from between two backtick runs
            // joins them in the output, and a count taken before the drop would
            // size the fence for two short runs instead of the one long one the
            // reader ends up with.
            if byte != UInt8(ascii: "\t"), byte < 0x20 || byte == 0x7F {
                continue
            }
            kept.append(byte)
            if byte == UInt8(ascii: "`") {
                backtickRun += 1
                if backtickRun > maximumBacktickRun {
                    // Cut at the start of the offending line, so the document
                    // never ends inside a run the fence could not contain.
                    kept.removeSubrange(lastLineStart...)
                    return SanitizedBody(bytes: kept, wasCut: true)
                }
            } else {
                backtickRun = 0
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
