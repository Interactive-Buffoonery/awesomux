import AwesoMuxCore
import SwiftUI

// MARK: - MarkdownView

/// Renders a `[MarkdownBlock]` array produced by `MarkdownRenderModelBuilder`.
///
/// This is a read-only viewer — no editing, no interaction beyond links
/// (which open via the system `openURL` environment). It uses native SwiftUI
/// `Text` composition and deliberate font/spacing choices to produce a
/// readable document feel that matches the app's typography.
///
/// Accessibility: SwiftUI `Text` is natively accessible. Block structure maps
/// naturally to what VoiceOver expects — headings read their text, paragraphs
/// flow, code blocks are monospaced static text.
struct MarkdownView: View {
    let blocks: [MarkdownBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(blocks.indices, id: \.self) { index in
                BlockView(block: blocks[index])
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - BlockView

private struct BlockView: View {
    let block: MarkdownBlock

    var body: some View {
        switch block {
        case let .heading(level, inlines):
            HeadingView(level: level, inlines: inlines)

        case let .paragraph(inlines):
            InlineText(inlines: inlines)
                .fixedSize(horizontal: false, vertical: true)

        case let .codeBlock(_, code):
            CodeBlockView(code: code)

        case let .blockQuote(blocks):
            BlockQuoteView(blocks: blocks)

        case let .unorderedList(items):
            UnorderedListView(items: items)

        case let .orderedList(start, items):
            OrderedListView(start: start, items: items)

        case .thematicBreak:
            Divider()
        }
    }
}

// MARK: - HeadingView

private struct HeadingView: View {
    let level: Int
    let inlines: [MarkdownInline]

    var body: some View {
        InlineText(inlines: inlines)
            .font(headingFont)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }

    private var headingFont: Font {
        switch level {
        case 1: return .largeTitle.bold()
        case 2: return .title.bold()
        case 3: return .title2.bold()
        case 4: return .title3.bold()
        case 5: return .headline
        default: return .subheadline.bold()
        }
    }
}

// MARK: - CodeBlockView

private struct CodeBlockView: View {
    let code: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(code)
                .font(.system(.body, design: .monospaced))
                .padding(10)
                // Intrinsic width (not maxWidth: .infinity) so long lines extend
                // past the viewport and the horizontal scroll actually engages
                // instead of wrapping (OpenCode review).
                .fixedSize(horizontal: true, vertical: false)
        }
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.12))
        )
    }
}

// MARK: - BlockQuoteView

private struct BlockQuoteView: View {
    let blocks: [MarkdownBlock]

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Rectangle()
                .fill(Color.accentColor.opacity(0.6))
                .frame(width: 3)
                .cornerRadius(1.5)

            MarkdownView(blocks: blocks)
                .foregroundStyle(.primary)
                .padding(.leading, 10)
        }
    }
}

// MARK: - UnorderedListView

private struct UnorderedListView: View {
    let items: [[MarkdownBlock]]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items.indices, id: \.self) { index in
                HStack(alignment: .top, spacing: 6) {
                    Text("•")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)  // decorative; VoiceOver reads item content only
                    MarkdownView(blocks: items[index])
                }
            }
        }
        .padding(.leading, 8)
    }
}

// MARK: - OrderedListView

private struct OrderedListView: View {
    let start: Int
    let items: [[MarkdownBlock]]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items.indices, id: \.self) { index in
                HStack(alignment: .top, spacing: 6) {
                    Text("\(start + index).")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    MarkdownView(blocks: items[index])
                }
            }
        }
        .padding(.leading, 8)
    }
}

// MARK: - InlineText

/// Builds a SwiftUI `Text` value by concatenating styled fragments from
/// `[MarkdownInline]`. Using `Text` concatenation (not `AttributedString`)
/// keeps nesting simple and avoids AppKit/UIKit bridging.
///
/// Links are rendered as PLAIN text in PR1 — no accent colour, no underline —
/// to avoid a false clickable affordance in a read-only viewer. Real link
/// navigation is deferred to PR2.
private struct InlineText: View {
    let inlines: [MarkdownInline]

    var body: some View {
        buildText(from: inlines)
    }

    private func buildText(from inlines: [MarkdownInline]) -> Text {
        inlines.reduce(Text("")) { acc, inline in acc + text(for: inline) }
    }

    private func text(for inline: MarkdownInline) -> Text {
        switch inline {
        case let .text(s):
            return Text(s)

        case let .emphasis(children):
            return buildText(from: children).italic()

        case let .strong(children):
            return buildText(from: children).bold()

        case let .strikethrough(children):
            return buildText(from: children).strikethrough()

        case let .code(s):
            // Use .primary instead of .secondary: .secondary can fail contrast
            // over the user's terminal theme. The monospaced font already
            // differentiates inline code visually without a colour change.
            return Text(s)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.primary)

        case let .link(_, children):
            // PR1: plain text — no accent colour, no underline. A false
            // clickable affordance in a read-only viewer misleads users.
            // Real link navigation is deferred to PR2.
            return buildText(from: children)

        case .softBreak:
            // A soft break (bare newline in the source) joins adjacent lines
            // with a space so hard-wrapped prose flows as one paragraph.
            return Text(" ")

        case .lineBreak:
            return Text("\n")
        }
    }
}
