import Markdown

// MARK: - Builder

/// Maps a raw markdown string to `[MarkdownBlock]` via swift-markdown's AST.
///
/// Mapping decisions (PR1):
/// - `SoftBreak`: mapped to `.softBreak`. The view renders it as a space so
///   hard-wrapped prose (80-col git convention) flows as a single paragraph.
/// - `LineBreak` (two trailing spaces / backslash): mapped to `.lineBreak` (hard break).
/// - `Image`: alt text is emitted as `.text` so the reader still gets context; no
///   network/image loading is attempted.
/// - `Table`: dropped (not rendered in PR1).
/// - `InlineHTML` tags (`<mark>`, `</mark>`, etc.): stripped — no output for the tag.
///   The tag's content is ordinary `Text` children in the AST, so stripping the tag
///   node is enough; the text child is processed normally.
/// - `HTMLBlock` and HTML comments (`<!-- ... -->`): dropped entirely.
public enum MarkdownRenderModelBuilder {
    /// Parse `markdown` and return the corresponding render model blocks.
    public static func build(_ markdown: String) -> [MarkdownBlock] {
        let document = Document(parsing: MarkdownFrontMatter.bodySource(from: markdown))
        return blocks(from: document.children)
    }
}

// MARK: - Block mapping

private func blocks(from children: MarkupChildren) -> [MarkdownBlock] {
    children.compactMap { block(from: $0) }
}

private func block(from markup: any Markup) -> MarkdownBlock? {
    switch markup {
    case let heading as Heading:
        return .heading(level: heading.level, inlines(from: heading.children))

    case let paragraph as Paragraph:
        return .paragraph(inlines(from: paragraph.children))

    case let code as CodeBlock:
        // swift-markdown returns an empty string for language when unspecified; normalise to nil.
        let lang: String? = code.language.flatMap { $0.isEmpty ? nil : $0 }
        // swift-markdown appends a trailing newline to the code string; trim it so tests match.
        let rawCode = code.code
        let trimmed = rawCode.hasSuffix("\n") ? String(rawCode.dropLast()) : rawCode
        return .codeBlock(language: lang, code: trimmed)

    case let quote as BlockQuote:
        return .blockQuote(blocks(from: quote.children))

    case let list as UnorderedList:
        let items: [[MarkdownBlock]] = list.listItems.map { blocks(from: $0.children) }
        return .unorderedList(items)

    case let list as OrderedList:
        let items: [[MarkdownBlock]] = list.listItems.map { blocks(from: $0.children) }
        // startIndex is UInt; safe to cast to Int for the model (reasonable list sizes).
        return .orderedList(start: Int(list.startIndex), items: items)

    case is ThematicBreak:
        return .thematicBreak

    case is HTMLBlock:
        // Drop raw HTML blocks and HTML comments entirely.
        return nil

    default:
        // Unknown / out-of-scope nodes (Table, BlockDirective, …) are dropped.
        return nil
    }
}

// MARK: - Inline mapping

private func inlines(from children: MarkupChildren) -> [MarkdownInline] {
    children.flatMap { inline(from: $0) }
}

private func inline(from markup: any Markup) -> [MarkdownInline] {
    switch markup {
    case let text as Text:
        return [.text(text.string)]

    case let em as Emphasis:
        return [.emphasis(inlines(from: em.children))]

    case let strong as Strong:
        return [.strong(inlines(from: strong.children))]

    case let strike as Strikethrough:
        return [.strikethrough(inlines(from: strike.children))]

    case let code as InlineCode:
        return [.code(code.code)]

    case let link as Link:
        return [.link(destination: link.destination, inlines(from: link.children))]

    case is LineBreak:
        return [.lineBreak]

    case is SoftBreak:
        // Soft breaks represent a line continuation in the source (e.g. a bare
        // newline in an 80-col-wrapped paragraph). Render as `.softBreak` so the
        // view can join adjacent lines with a space instead of a newline.
        return [.softBreak]

    case is InlineHTML:
        // Strip all inline HTML tags (including <mark>, </mark>, comments).
        // The tag's text children are processed as ordinary inlines by the caller.
        return []

    case let image as Image:
        // Images are out of scope for PR1. Emit alt text as plain text so the
        // reader still gets context. `Image.plainText` collapses child inlines.
        let alt = image.plainText
        return alt.isEmpty ? [] : [.text(alt)]

    default:
        return []
    }
}
