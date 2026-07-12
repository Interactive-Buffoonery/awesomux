// Intermediate render model for markdown content.
// Produced by MarkdownRenderModelBuilder from a raw markdown string.
// Task 5b renders this model in SwiftUI; this file has no SwiftUI dependency.

// MARK: - Inline elements

/// An inline markdown element.
public enum MarkdownInline: Equatable, Sendable {
    case text(String)
    case emphasis([MarkdownInline])      // italic
    case strong([MarkdownInline])        // bold
    case strikethrough([MarkdownInline])
    case code(String)                    // inline code span
    case link(destination: String?, [MarkdownInline])
    /// A soft line break (newline in the source with no trailing spaces). Renders
    /// as a space so hard-wrapped prose flows as a single paragraph.
    case softBreak
    /// A hard line break (two trailing spaces or backslash in the source).
    /// Renders as a newline.
    case lineBreak
}

// MARK: - Block elements

/// A block-level markdown element.
public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, [MarkdownInline])
    case paragraph([MarkdownInline])
    case codeBlock(language: String?, code: String)
    case blockQuote([MarkdownBlock])
    case unorderedList([[MarkdownBlock]])              // each item = [MarkdownBlock]
    case orderedList(start: Int, items: [[MarkdownBlock]])
    case thematicBreak
}
