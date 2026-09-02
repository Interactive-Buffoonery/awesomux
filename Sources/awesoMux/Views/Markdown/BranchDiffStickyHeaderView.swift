import AppKit

/// The branch-changes file heading that stays pinned to the top of the pane
/// while its section's body scrolls underneath, and is pushed out of the way by
/// the next file's heading as that heading reaches the top edge.
///
/// Deliberately NOT an accessibility element: `CommentBadgeOverlay` already
/// exposes one button per heading with the same label and value, and the
/// document text carries the heading itself. A third identity per file is noise
/// rather than access.
@MainActor
final class BranchDiffStickyHeaderView: NSView {
    struct Model: Equatable {
        let key: String
        let title: String
        let added: Int
        let removed: Int
        let collapsed: Bool
    }

    /// Where the header sits for a given scroll position. A struct rather than a
    /// tuple so the optional result is `Equatable`.
    struct Placement: Equatable {
        let index: Int
        let pushOffset: CGFloat
    }

    static let height: CGFloat = 30

    /// Pinned section and how far the next heading has pushed the header up, for
    /// a visible top edge in document (flipped) coordinates. `rows` are the
    /// heading row rects in document order. Nil when no heading has reached the
    /// top edge yet — nothing to pin.
    ///
    /// A heading whose `minY` equals `visibleTop` counts as pinned: the drawn
    /// header covers the in-place heading exactly, so nothing shows twice.
    nonisolated static func placement(
        visibleTop: CGFloat,
        rows: [(minY: CGFloat, maxY: CGFloat)],
        headerHeight: CGFloat
    ) -> Placement? {
        // ponytail: linear scan, binary search if a thousand-file diff makes this show up
        var pinned: Int? = nil
        for (offset, row) in rows.enumerated() {
            guard row.minY <= visibleTop else { break }
            pinned = offset
        }
        guard let pinned else { return nil }
        let next = pinned + 1
        let pushOffset =
            next < rows.count ? min(0, rows[next].minY - visibleTop - headerHeight) : 0
        return Placement(index: pinned, pushOffset: pushOffset)
    }

    var model: Model? {
        didSet {
            guard oldValue != model else { return }
            isHidden = model == nil
            refreshContent()
        }
    }

    /// Click, or the test seam, resolved to the pinned section's key.
    var onActivate: ((String) -> Void)? = nil

    var backgroundColor: NSColor = .windowBackgroundColor {
        didSet { if oldValue != backgroundColor { applyBackground() } }
    }
    var titleColor: NSColor = .labelColor {
        didSet { if oldValue != titleColor { refreshContent() } }
    }
    var addedColor: NSColor = .systemGreen {
        didSet { if oldValue != addedColor { refreshContent() } }
    }
    var removedColor: NSColor = .systemRed {
        didSet { if oldValue != removedColor { refreshContent() } }
    }
    var ruleColor: NSColor = .separatorColor {
        didSet { if oldValue != ruleColor { needsDisplay = true } }
    }

    /// Matches the text view's `textContainerInset.width` so the pinned title
    /// lines up with the heading it replaces. Pushed by the coordinator.
    var contentInset: CGFloat = 20 {
        didSet { if oldValue != contentInset { needsLayout = true } }
    }

    private let chevron = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let countsLabel = NSTextField(labelWithString: "")

    private static let titleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    private static let countsFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // didSet never fires for the initial nil model, so the starting hidden
        // state has to be set here.
        isHidden = true
        setAccessibilityElement(false)
        for label in [titleLabel, countsLabel] {
            label.lineBreakMode = .byTruncatingMiddle
            label.setAccessibilityElement(false)
            addSubview(label)
        }
        titleLabel.font = Self.titleFont
        countsLabel.font = Self.countsFont
        chevron.imageScaling = .scaleNone
        chevron.setAccessibilityElement(false)
        addSubview(chevron)
        applyBackground()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        let gutter = MarkdownAttributedStringBuilder.sectionHeadingGutter
        let chevronSize = chevron.image?.size ?? .zero
        chevron.frame = NSRect(
            x: contentInset + (gutter - chevronSize.width) / 2,
            y: (bounds.height - chevronSize.height) / 2,
            width: chevronSize.width,
            height: chevronSize.height)

        let countsSize = countsLabel.attributedStringValue.size()
        countsLabel.frame = NSRect(
            x: bounds.maxX - contentInset - countsSize.width,
            y: (bounds.height - countsSize.height) / 2,
            width: countsSize.width,
            height: countsSize.height)

        let titleX = contentInset + gutter
        let titleHeight = titleLabel.intrinsicContentSize.height
        titleLabel.frame = NSRect(
            x: titleX,
            y: (bounds.height - titleHeight) / 2,
            width: max(0, countsLabel.frame.minX - 8 - titleX),
            height: titleHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        ruleColor.setFill()
        // Unflipped: the header's own bottom edge is y == 0.
        NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: 1).fill()
    }

    override func mouseDown(with event: NSEvent) {
        activate()
    }

    /// Test seam: headless tests have no window to route a real mouse event.
    func simulateClick() {
        activate()
    }

    private func activate() {
        guard let key = model?.key else { return }
        onActivate?(key)
    }

    private func applyBackground() {
        layer?.backgroundColor = backgroundColor.cgColor
    }

    private func refreshContent() {
        guard let model else { return }
        titleLabel.stringValue = model.title
        titleLabel.textColor = titleColor
        countsLabel.attributedStringValue = countsAttributedString(
            added: model.added, removed: model.removed)
        chevron.image = chevronImage(collapsed: model.collapsed)
        needsLayout = true
        needsDisplay = true
    }

    private func countsAttributedString(added: Int, removed: Int) -> NSAttributedString {
        let text = CommentBadgeOverlay.countsBadgeText(added: added, removed: removed)
        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [.font: Self.countsFont, .foregroundColor: addedColor])
        let minus = (text as NSString).range(of: "\u{2212}")
        if minus.location != NSNotFound {
            attributed.addAttribute(
                .foregroundColor, value: removedColor,
                range: NSRange(
                    location: minus.location, length: (text as NSString).length - minus.location))
        }
        return attributed
    }

    private func chevronImage(collapsed: Bool) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [titleColor]))
        return NSImage(
            systemSymbolName: collapsed ? "chevron.right" : "chevron.down",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(configuration)
    }
}
