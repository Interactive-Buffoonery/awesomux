// Sources/AwesoMuxCore/Markdown/RenderedDocument.swift
//
// Flat run model produced by AttributedMarkdownBuilder.
// Each RenderedRun carries the text the view renders plus source metadata that
// AttributedMarkdownEditor uses to map user selections back to raw Markdown bytes.

// MARK: - TableColumnAlignment

/// Per-column text alignment for a GFM table. AppKit-free (the `awesoMux`-target
/// attributed-string builder maps this to `NSTextAlignment`) so `AwesoMuxCore`
/// stays free of any AppKit import.
public enum TableColumnAlignment: Equatable, Sendable {
    case left
    case center
    case right
}

// MARK: - DiffLineKind

/// The role of one line inside a ```` ```diff ```` fence, classified from its
/// unified-diff prefix so the view can color it. Nothing here inspects the
/// line's content past that prefix.
public enum DiffLineKind: Equatable, Sendable {
    case added
    case removed
    /// `@@ -a,b +c,d @@` hunk header.
    case hunk
    /// Per-file header lines (`diff --git`, `index`, `---`/`+++`, mode and
    /// rename lines) and `\ No newline at end of file`.
    case meta
    case context

    /// Classifies a raw diff line. Prefix-only, on purpose: a line inside a
    /// hunk is always prefixed with a space, `+`, or `-`, so the file-header
    /// vocabulary can only match at a hunk boundary — except `--- `/`+++ `,
    /// which a removed SQL comment or an added `++` line could imitate. Those
    /// two also require the path shape git prints after them, which narrows
    /// the collision to content that itself reads `-- a/…` or `++ b/…`; the
    /// cost of that residual collision is a dimmed line, nothing more.
    public init(line: Substring) {
        if line.hasPrefix("@@") {
            self = .hunk
        } else if line.hasPrefix("+++ ") || line.hasPrefix("--- ") {
            let rest = line.dropFirst(4)
            self =
                rest.hasPrefix("a/") || rest.hasPrefix("b/") || rest == "/dev/null"
                ? .meta
                : (line.hasPrefix("+") ? .added : .removed)
        } else if line.hasPrefix("+") {
            self = .added
        } else if line.hasPrefix("-") {
            self = .removed
        } else if line.hasPrefix("\\ ") || Self.metaPrefixes.contains(where: { line.hasPrefix($0) }) {
            self = .meta
        } else {
            self = .context
        }
    }

    private static let metaPrefixes = [
        "diff --git ", "index ", "old mode ", "new mode ", "new file mode ", "deleted file mode ",
        "similarity index ", "dissimilarity index ", "rename from ", "rename to ", "copy from ",
        "copy to ", "Binary files ",
    ]
}

// MARK: - RunStyle

/// Visual / semantic role of a `RenderedRun`.
public enum RunStyle: Equatable, Sendable {
    case frontMatter
    case body
    case heading(level: Int)
    case code
    /// One line of a ```` ```diff ```` fence. Each line is its own run so the
    /// view can color and indent it independently; the run text excludes the
    /// line's newline, which follows as a `.blockSeparator`.
    case diffLine(DiffLineKind)
    case listBullet
    case listNumber(String)     // e.g. "1.", "2."
    case blockSeparator         // "\n\n" between blocks, " " for soft breaks, "\n" for hard breaks

    /// A header-row cell. `table` is a per-document serial grouping every run of
    /// one table; `row`/`column` are the cell's block position; `alignment` is the
    /// column's GFM alignment. The attributed-string builder uses these to build a
    /// shared tab-stop paragraph style and stroke the grid.
    case tableHeader(table: Int, row: Int, column: Int, alignment: TableColumnAlignment)
    /// A body-row cell. See `tableHeader` for the associated values.
    case tableCell(table: Int, row: Int, column: Int, alignment: TableColumnAlignment)

    /// The `(table, row, column)` identity for table-cell styles, else nil.
    /// Lets callers group/compare cells without repeating the associated-value match.
    public var tableCellPosition: (table: Int, row: Int, column: Int)? {
        switch self {
        case let .tableHeader(table, row, column, _),
             let .tableCell(table, row, column, _):
            return (table, row, column)
        default:
            return nil
        }
    }
}

// MARK: - RenderedRun

/// A single atomic run in the flat run sequence produced by `AttributedMarkdownBuilder`.
///
/// ## Source-range contract
/// - `sourceRange` is always non-nil for runs that originate from real source nodes
///   (plain text, inline code, fenced code, links, emphasis children, etc.).
/// - `sourceRange` is nil for **synthetic** runs: list bullets, separators, hard/soft breaks.
/// - `preciseMapping` is true iff `text.utf8.count == (sourceRange.upperBound - sourceRange.lowerBound)`.
///   Inline/fenced code and entity-bearing text are always `false` because their source
///   representation differs from the decoded text (backtick delimiters, `&amp;` → `&`, etc.).
/// - `enclosingRange` is the byte range of the top-level inline construct directly under the
///   block (e.g. `**b**` for a bold run inside `"a **b** c"`). Used so a selection that snaps
///   to a mark's enclosing node is guaranteed to start/end at markup-safe boundaries.
///
/// ## markID
/// Non-nil only for runs enclosed in `<mark>…</mark>` blocks paired with an
/// annotation marker — `<!-- AMX id=… -->` or legacy `<!-- USER COMMENT N -->`.
/// The value is the annotation's id (the legacy integer as a string).
public struct RenderedRun: Equatable, Sendable {
    public var text: String
    public var style: RunStyle
    public var bold: Bool
    public var italic: Bool
    public var strikethrough: Bool
    /// Monospaced (inline code) rendering as an orthogonal trait, like `bold`/`italic`.
    /// A code run inside a table cell is re-styled `.tableCell` for grid membership, so
    /// its code-ness can no longer live in `style`; this flag carries it instead.
    public var monospaced: Bool
    public var linkDestination: String?
    public var sourceRange: Range<Int>?
    public var enclosingRange: Range<Int>?
    public var preciseMapping: Bool
    public var markID: String?

    public init(
        text: String,
        style: RunStyle,
        bold: Bool = false,
        italic: Bool = false,
        strikethrough: Bool = false,
        monospaced: Bool = false,
        linkDestination: String? = nil,
        sourceRange: Range<Int>?,
        enclosingRange: Range<Int>?,
        preciseMapping: Bool,
        markID: String? = nil
    ) {
        self.text = text
        self.style = style
        self.bold = bold
        self.italic = italic
        self.strikethrough = strikethrough
        self.monospaced = monospaced
        self.linkDestination = linkDestination
        self.sourceRange = sourceRange
        self.enclosingRange = enclosingRange
        self.preciseMapping = preciseMapping
        self.markID = markID
    }
}

// MARK: - RenderedDocument

/// Completion summary for GFM task-list items in a rendered Markdown document.
public struct TaskProgress: Equatable, Sendable {
    public let done: Int
    public let total: Int

    public init(done: Int, total: Int) {
        self.done = done
        self.total = total
    }
}

/// The flat output of `AttributedMarkdownBuilder`.
///
/// `runs` is the full sequence of runs whose `text` fields, when joined, equal exactly
/// what the view renders (invariant: no `<mark>`, `</mark>`, or `<!-- … -->` markup text).
///
/// `annotations` are the document's plan annotations in document order —
/// AMX markers plus legacy `USER COMMENT` markers (docs/plan-annotations.md).
public struct RenderedDocument: Sendable {
    public let source: String
    public let runs: [RenderedRun]
    public let annotations: [PlanAnnotation]
    public let taskProgress: TaskProgress

    public init(
        source: String,
        runs: [RenderedRun],
        annotations: [PlanAnnotation],
        taskProgress: TaskProgress
    ) {
        self.source = source
        self.runs = runs
        self.annotations = annotations
        self.taskProgress = taskProgress
    }

    public func annotation(id: String) -> PlanAnnotation? {
        annotations.first { $0.id == id }
    }

    /// Feed for the inline resolution tracker (INT-683). The single
    /// whole-document note has its own status affordance and does not count as
    /// an inline review item.
    public var openAnnotationCount: Int {
        annotations.count { $0.anchor == .span && $0.status == .open }
    }

    /// Open annotation ids in source/document order for provider handoff. This
    /// includes the single document-level note as well as span annotations;
    /// ids are the only annotation data that crosses into the staged prompt.
    public var openAnnotationIDs: [String] {
        annotations.filter { $0.status == .open }.map(\.id)
    }

    /// Ids of resolved span annotations, for de-emphasized highlight rendering.
    public var resolvedAnnotationIDs: Set<String> {
        Set(annotations.filter { $0.anchor == .span && $0.status == .resolved }.map(\.id))
    }

    /// Count of resolved span annotations, for the resolved-filter affordance.
    /// Cheaper than `resolvedAnnotationIDs.count` on per-render paths.
    public var resolvedAnnotationCount: Int {
        annotations.count { $0.anchor == .span && $0.status == .resolved }
    }

    /// The document's single whole-document note, when present.
    public var documentNote: PlanAnnotation? {
        annotations.first { $0.anchor == .document }
    }

    /// 1-based badge number for a span annotation, by document order among
    /// span annotations. Cosmetic grouping only — ids are the identity.
    public func displayNumber(for id: String) -> Int? {
        let spanIDs = annotations.filter { $0.anchor == .span }.map(\.id)
        guard let index = spanIDs.firstIndex(of: id) else { return nil }
        return index + 1
    }
}
