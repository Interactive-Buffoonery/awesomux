// Sources/AwesoMuxCore/Markdown/PlanAnnotation.swift
//
// The document-level aggregate for one plan annotation: an AMX marker (or a
// legacy USER COMMENT marker) plus any thread notes that reference its id.
// Built by AttributedMarkdownBuilder; docs/plan-annotations.md is the contract.

/// One annotation in a rendered document, in document order.
public struct PlanAnnotation: Equatable, Sendable {
    public enum Anchor: Equatable, Sendable {
        /// Attached to a `<mark>…</mark>` span; the span's runs carry this
        /// annotation's id in `RenderedRun.markID`.
        case span
        /// Targets the whole document; no highlighted span.
        case document
    }

    /// A thread reply (`<!-- AMX re=<id> by=…: … -->`), in file order.
    public struct Note: Equatable, Sendable {
        public let author: PlanAnnotationAuthor
        public let payload: String

        public init(author: PlanAnnotationAuthor, payload: String) {
            self.author = author
            self.payload = payload
        }
    }

    public let id: String
    public var author: PlanAnnotationAuthor
    public var intent: PlanAnnotationIntent
    public var status: PlanAnnotationStatus
    public var payload: String
    public var anchor: Anchor
    /// True when parsed from the legacy `<!-- USER COMMENT N: … -->` form.
    /// Legacy annotations keep integer-string ids and upgrade to the AMX form
    /// only when a write touches them (contract: no bulk file migration).
    public var isLegacy: Bool
    public var notes: [Note]

    public init(
        id: String,
        author: PlanAnnotationAuthor,
        intent: PlanAnnotationIntent = .comment,
        status: PlanAnnotationStatus = .open,
        payload: String,
        anchor: Anchor,
        isLegacy: Bool = false,
        notes: [Note] = []
    ) {
        self.id = id
        self.author = author
        self.intent = intent
        self.status = status
        self.payload = payload
        self.anchor = anchor
        self.isLegacy = isLegacy
        self.notes = notes
    }
}
