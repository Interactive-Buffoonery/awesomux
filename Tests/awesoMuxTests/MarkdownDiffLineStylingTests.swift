import AppKit
import AwesoMuxCore
import Testing

@testable import awesoMux

@Suite("Markdown diff line styling")
struct MarkdownDiffLineStylingTests {

    private func attributes(
        ofLine needle: String, in doc: RenderedDocument, terminalBackground: NSColor? = nil
    ) -> [NSAttributedString.Key: Any] {
        let attributed = MarkdownAttributedStringBuilder.attributedString(
            for: doc, textColor: .white, terminalBackground: terminalBackground)
        let range = (attributed.string as NSString).range(of: needle)
        return attributed.attributes(at: range.location, effectiveRange: nil)
    }

    @Test("added and removed rows carry distinct tints and a sign in that tint's hue; context carries none")
    func addedAndRemovedAreTinted() throws {
        let doc = AttributedMarkdownBuilder.build("```diff\n context\n-old\n+new\n```\n")
        let removedTint = try #require(attributes(ofLine: "-old", in: doc)[.diffLineTint] as? NSColor)
        let addedTint = try #require(attributes(ofLine: "+new", in: doc)[.diffLineTint] as? NSColor)
        #expect(addedTint != removedTint)
        #expect(attributes(ofLine: " context", in: doc)[.diffLineTint] == nil)
        // The sign is the one glyph in the full hue; the code after it stays body-colored.
        let sign = try #require(attributes(ofLine: "+", in: doc)[.foregroundColor] as? NSColor)
        let text = try #require(attributes(ofLine: "new", in: doc)[.foregroundColor] as? NSColor)
        let context = try #require(attributes(ofLine: " context", in: doc)[.foregroundColor] as? NSColor)
        #expect(sign == addedTint)
        #expect(text == context)
    }

    @Test("the tint attribute is stamped even when no text color is supplied")
    func tintDoesNotDependOnTextColor() throws {
        let doc = AttributedMarkdownBuilder.build("```diff\n+new\n```\n")
        let attributed = MarkdownAttributedStringBuilder.attributedString(for: doc)
        #expect(attributed.attribute(.diffLineTint, at: 0, effectiveRange: nil) != nil)
    }

    @Test("hues are tuned to the terminal background, not the app appearance")
    func huesFollowTheTerminalBackground() throws {
        let doc = AttributedMarkdownBuilder.build("```diff\n+new\n```\n")
        let onDark = try #require(attributes(ofLine: "+", in: doc, terminalBackground: .black)[.foregroundColor] as? NSColor)
        let onLight = try #require(attributes(ofLine: "+", in: doc, terminalBackground: .white)[.foregroundColor] as? NSColor)
        #expect(onDark != onLight)
        // Mocha green is bright; Latte green is dark. Each hue is text, so it must clear the AA 4.5:1 floor on its own surface.
        #expect(MarkdownAttributedStringBuilderContrast.ratio(onDark, against: .black) >= 4.5)
        #expect(MarkdownAttributedStringBuilderContrast.ratio(onLight, against: .white) >= 4.5)
        // And it stays a hue, not the black/white fallback.
        #expect((onLight.usingColorSpace(.sRGB)?.greenComponent ?? 0) > (onLight.usingColorSpace(.sRGB)?.redComponent ?? 1))
    }

    @Test("diff lines are monospaced and wrap under a hanging indent")
    func diffLinesAreMonospacedWithHangingIndent() throws {
        let doc = AttributedMarkdownBuilder.build("```diff\n+new\n```\n")
        let attributes = attributes(ofLine: "+new", in: doc)
        let font = try #require(attributes[.font] as? NSFont)
        #expect(font.isFixedPitch)
        let paragraph = try #require(attributes[.paragraphStyle] as? NSParagraphStyle)
        #expect(paragraph.headIndent > 0)
        #expect(paragraph.firstLineHeadIndent == 0)
    }

    @Test("a plain code fence keeps its single dimmed run and no diff paragraph style")
    func plainFenceIsUntouched() throws {
        let doc = AttributedMarkdownBuilder.build("```\n+not a diff\n```\n")
        let attributes = attributes(ofLine: "+not a diff", in: doc)
        #expect(attributes[.paragraphStyle] == nil)
        let color = try #require(attributes[.foregroundColor] as? NSColor)
        #expect(color.alphaComponent < 1)
    }

    // MARK: - Overlay row washes

    /// TextKit 2 text view configured like `MarkdownTextView.makeNSView`, with
    /// layout forced so fragment geometry exists without a window.
    @MainActor
    private func makeTextView(_ source: String) -> NSTextView {
        let textView = NSTextView(usingTextLayoutManager: true)
        textView.frame = NSRect(x: 0, y: 0, width: 300, height: 400)
        textView.textContainerInset = NSSize(width: 20, height: 20)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let doc = AttributedMarkdownBuilder.build(source)
        textView.textStorage?.setAttributedString(
            MarkdownAttributedStringBuilder.attributedString(for: doc, textColor: .white))
        textView.textLayoutManager?.ensureLayout(for: textView.textLayoutManager!.documentRange)
        return textView
    }

    @Test("consecutive same-colored rows merge into one full-width wash; a context line or a color change splits them")
    @MainActor
    func rowWashesMergeAcrossConsecutiveLines() throws {
        let textView = makeTextView("```diff\n+a\n+b\n+c\n context\n-d\n-e\n```\n")
        let rows = CommentBadgeOverlay.diffTintRows(
            intersecting: NSRect(x: 0, y: 0, width: 300, height: 4000), in: textView, width: 300)
        #expect(rows.count == 2)
        let added = try #require(rows.first)
        let removed = try #require(rows.last)
        #expect(added.color != removed.color)
        #expect(rows.allSatisfy { $0.rect.minX == 0 && $0.rect.width == 300 })
        // Three lines merged: the added wash is about 1.5× the two-line removed wash.
        #expect(added.rect.height > removed.rect.height * 1.3)
        #expect(added.rect.height < removed.rect.height * 1.7)
        // The context line sits in the gap between them.
        #expect(removed.rect.minY > added.rect.maxY + 1)
    }

    @Test("only rows intersecting the requested rect are produced")
    @MainActor
    func rowWashesAreLimitedToTheRect() throws {
        let body = (0..<200).map { "+line \($0)" }.joined(separator: "\n")
        let textView = makeTextView("```diff\n\(body)\n```\n")
        let all = CommentBadgeOverlay.diffTintRows(
            intersecting: NSRect(x: 0, y: 0, width: 300, height: 100_000), in: textView, width: 300)
        let top = CommentBadgeOverlay.diffTintRows(
            intersecting: NSRect(x: 0, y: 0, width: 300, height: 60), in: textView, width: 300)
        #expect(all.count == 1)
        #expect(top.count == 1)
        #expect(try #require(top.first).rect.height < #require(all.first).rect.height)
    }
}

/// WCAG relative-luminance contrast, local to this suite so the assertion
/// does not depend on a design-system internal.
enum MarkdownAttributedStringBuilderContrast {
    static func ratio(_ a: NSColor, against b: NSColor) -> CGFloat {
        func luminance(_ color: NSColor) -> CGFloat {
            let c = color.usingColorSpace(.sRGB) ?? color
            func channel(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * channel(c.redComponent) + 0.7152 * channel(c.greenComponent) + 0.0722 * channel(c.blueComponent)
        }
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
}
