import AppKit
import AwesoMuxCore
import SwiftUI

// MARK: - SelectionAwareTextView

/// NSTextView subclass that notifies a coordinator when the user finalizes a
/// mouse-based selection. We override `mouseDown(with:)` rather than `mouseUp`:
///
/// NSTextView handles drag-selection entirely inside a mouse-tracking loop that
/// it starts inside `mouseDown`. `super.mouseDown(with:)` BLOCKS — it does not
/// return until the mouse button is released, having consumed the entire drag
/// (and the implicit mouseUp) internally. As a result, our `mouseUp(with:)`
/// override is frequently NEVER called for drag-selections; AppKit's own tracking
/// loop eats the event before it propagates outward.
///
/// By reading `selectedRange()` immediately AFTER `super.mouseDown(with:)` returns
/// we see the fully-committed post-drag selection synchronously — the tracking loop
/// has finished and the range is stable. We compare to the pre-call `before` range
/// so a plain click (no drag, before==after, length==0) is ignored.
@MainActor
final class SelectionAwareTextView: NSTextView {
    /// Called after mouseDown's tracking loop finalizes the selection. Args: the text view.
    var onSelectionFinished: ((NSTextView) -> Void)? = nil

    override func mouseDown(with event: NSEvent) {
        let before = selectedRange()
        super.mouseDown(with: event)  // blocks through NSTextView's drag-tracking loop until mouse-up
        let after = selectedRange()
        guard after.length > 0, after != before else { return }
        onSelectionFinished?(self)
    }
}

// MARK: - MarkdownTextView

/// NSViewRepresentable wrapper over a selectable, non-editable `NSTextView`
/// backed by `MarkdownAttributedStringBuilder`. Selection→source mapping lives
/// in Task 4 (SelectionSourceMapping); this view exposes the seam via
/// `selectedSourceSpan`.
///
/// ## INVARIANT
/// The `NSTextView`'s text storage string equals
/// `doc.runs.map(\.text).joined()` — no badge or markup characters inserted.
/// Highlights are `.backgroundColor` attributes only (Task 5); badges are
/// drawn by `CommentBadgeOverlay` (Task 5), a sibling overlay view.
///
/// ## Task seams
/// - `selectedSourceSpan` (Task 4): coordinator sets this from
///   `textViewDidChangeSelection`. Carries `nil` until SelectionSourceMapping
///   is wired in Task 4.
/// - `highlightColor` (Task 5): highlight tint for `<mark>` runs.
/// - `onPillClicked` (Bigfoot): callback when a comment `•••` pill is clicked.
/// - `onAddPillClicked` (Bigfoot): callback when the add `•••` pill is clicked.
/// - `selectionTouchesMark` (Bigfoot): suppresses the add pill when true.
/// - `onTextViewAvailable` (Bigfoot): surfaces NSTextView reference for popover anchoring.
/// - `scrollAnchorOffset` (Task 7): source offset to scroll-to on appear.
@MainActor
struct MarkdownTextView: NSViewRepresentable {
    let doc: RenderedDocument

    /// Task 4 seam: the selected source span in UTF-8 byte offsets.
    @Binding var selectedSourceSpan: Range<Int>?

    // Task 5/6/7 seams
    var highlightColor: NSColor = .systemYellow.withAlphaComponent(0.3)
    /// Adaptive text color derived from the terminal background (INT-562 dark-on-dark fix).
    var textColor: NSColor? = nil
    /// Directory used to resolve schemeless relative Markdown links in document panes.
    var relativeLinkBaseURL: URL? = nil
    /// Remote snapshots keep external web links actionable but render document
    /// links as plain text because they cannot safely resolve another file.
    var allowsDocumentLinks = true

    // Bigfoot seams
    /// Called when a comment pill is clicked. Args: markID, pill rect in overlay coords, overlay view.
    var onPillClicked: ((String, NSRect, NSView) -> Void)? = nil
    /// Called when the add pill is clicked. Args: pill rect in overlay coords, overlay view.
    var onAddPillClicked: ((NSRect, NSView) -> Void)? = nil
    /// When true, suppress the add pill (selection overlaps an existing mark).
    var selectionTouchesMark: Bool = false
    /// Called once with the NSTextView reference so the parent can anchor NSPopovers.
    var onTextViewAvailable: ((NSTextView) -> Void)? = nil

    /// Fix 3 (INT-562): called when the user FINALISES a text selection (mouseUp with a
    /// non-empty range that does not touch an existing mark). Args: source span, trailing
    /// glyph rect in text-view coords, the text view itself (for NSPopover anchoring).
    /// The parent uses this to auto-present the compose popover without a pill-click step.
    var onSelectionFinalized: ((Range<Int>, NSRect, NSTextView) -> Void)? = nil

    var scrollAnchorOffset: Int? = nil

    /// Task 7: called from `makeNSView`/`updateNSView` with a closure that captures
    /// the coordinator's `scrollAnchorSourceOffset()` method.
    var onRegisterScrollAnchorCapture: ((@escaping @MainActor () -> Int?) -> Void)? = nil

    /// INT-748 PR2: routes a clicked local-markdown link so the opened tab
    /// inherits this document's terminal association. External links are
    /// unaffected; when nil, document links fall back to `GhosttyRuntime.openURL`.
    var onOpenDocumentLink: ((URL) -> Void)? = nil

    /// Annotation ids whose highlight and pill are suppressed (the pane's
    /// hide-resolved filter, INT-580).
    var hiddenAnnotationIDs: Set<String> = []

    // MARK: - NSViewRepresentable

    func makeCoordinator() -> MarkdownTextViewCoordinator {
        MarkdownTextViewCoordinator(selectedSourceSpan: $selectedSourceSpan)
    }

    func attributedString(for doc: RenderedDocument) -> NSAttributedString {
        MarkdownAttributedStringBuilder.attributedString(
            for: doc,
            textColor: textColor,
            relativeLinkBaseURL: relativeLinkBaseURL,
            allowsDocumentLinks: allowsDocumentLinks
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        // INT-687: wide tables overflow horizontally instead of wrapping at the
        // pane edge. autohidesScrollers keeps the horizontal bar invisible for
        // documents whose content fits the pane (prose always does — it wraps).
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        // Give the text view a non-zero initial frame so the width-tracking text
        // container doesn't compute a negative width (frame.width − 2×inset) on
        // the first layout pass, which can produce a single unwrapped line until
        // the first resize. Match the scroll view's content size.
        //
        // Fix 3/mouseDown (INT-562): use SelectionAwareTextView (NSTextView subclass)
        // so we can override mouseDown(with:) to detect finalized selections.
        // NSTextView runs its entire drag-tracking loop inside mouseDown — super.mouseDown
        // blocks until the mouse is released. mouseUp(with:) is therefore often NEVER
        // called for drag-selections because the tracking loop consumes the event.
        // Reading selectedRange() after super.mouseDown returns gives the committed
        // post-drag selection synchronously, with no stale-range race.
        let textView = SelectionAwareTextView(frame: NSRect(origin: .zero, size: scrollView.contentSize))
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 20, height: 20)
        // INT-687: the container is effectively infinite in BOTH axes. Prose
        // still wraps to the pane, but via per-paragraph tailIndent (see
        // MarkdownTextViewCoordinator.updateDocumentGeometry) instead of the
        // container width — that decoupling is what lets a wide table row run
        // past the pane edge into a horizontal scroll while body text keeps
        // wrapping. The text view does NOT self-size (no resizable flags, no
        // autoresizing): its frame is computed deterministically from layout
        // usage in updateDocumentGeometry, so there is no sizing feedback loop.
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = []
        textView.delegate = context.coordinator

        // Wire the mouseDown-tracking-loop callback into the coordinator.
        textView.onSelectionFinished = { [weak coordinator = context.coordinator] tv in
            coordinator?.handleSelectionFinished(in: tv)
        }

        // Accessibility: a non-editable, selectable document.
        textView.setAccessibilityRole(.staticText)
        textView.setAccessibilityLabel("Document content")
        scrollView.setAccessibilityElement(false)

        scrollView.documentView = textView

        // Task 5 / Bigfoot: badge overlay. Pills are the only popover trigger —
        // clicking the highlighted text selects normally; only the •••  pill opens
        // the comment popover. Hit-testing and mouseDown live in CommentBadgeOverlay.
        //
        // The overlay is a subview OF THE TEXT VIEW (not the clip view): it then
        // rides the documentView as it scrolls, and shares the text view's flipped
        // coordinate space 1:1 so pill rects need no extra conversion. Adding it as
        // a clip-view sibling (the previous layout) left it non-scrolling AND in a
        // non-flipped space, which inverted Y and dropped top-of-document pills at
        // the pane bottom (INT-562 Bigfoot).
        let overlay = CommentBadgeOverlay(frame: textView.bounds)
        overlay.autoresizingMask = [.width, .height]
        context.coordinator.badgeOverlay = overlay
        textView.addSubview(overlay)

        context.coordinator.textView = textView

        // INT-687: pane resizes reach the coordinator through the clip view's
        // frame, which is the one geometry the prose wrap width depends on.
        // Selector-based observation self-unregisters on coordinator dealloc.
        scrollView.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(MarkdownTextViewCoordinator.clipViewFrameDidChange(_:)),
            name: NSView.frameDidChangeNotification,
            object: scrollView.contentView
        )

        // Surface the NSTextView reference to the parent for popover anchoring.
        onTextViewAvailable?(textView)

        // Task 7: register the scroll-anchor capture closure with the parent view.
        onRegisterScrollAnchorCapture?({ [weak coordinator = context.coordinator] in
            coordinator?.scrollAnchorSourceOffset()
        })

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        // Table grid stroke color tracks the adaptive body text color (dimmed) so
        // the grid reads on dark and light terminals. Drawn by the badge overlay
        // (a subview whose draw(_:) reliably fires under TextKit 2), not the text
        // view — a plain NSTextView.draw(_:) override is not invoked for the
        // TextKit-2 content pass.
        //
        // The border is the sole cue separating cells, so it carries real
        // information — WCAG 1.4.11 wants >= 3:1 non-text contrast. `textColor` is
        // already the legible body color for this background (high contrast at full
        // alpha); dimming it to 0.35 risked dropping the hairline below the floor.
        // Use 0.5 as the default, and go fully solid when the user has asked the
        // system to Increase Contrast.
        let base = textColor ?? .labelColor
        let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        context.coordinator.badgeOverlay?.tableBorderColor =
            increaseContrast ? base : base.withAlphaComponent(0.5)

        // Only re-build the attributed string when baked-in attributes change.
        // Text color and relative link base are part of the attributed string (not
        // post-passes like highlights), so changes must trigger a full rebuild just
        // like a source change.
        let textColorChanged = context.coordinator.lastTextColor != textColor
        let linkBaseChanged = context.coordinator.lastRelativeLinkBaseURL != relativeLinkBaseURL
        let documentLinkPolicyChanged =
            context.coordinator.lastAllowsDocumentLinks != allowsDocumentLinks
        // Capture before the coordinator's last* fields are overwritten below.
        // `docSourceChanged` = the document content actually changed (a reload).
        // `sourceChanged` additionally covers a textColor restyle, which must rebuild
        // the attributed string (color is baked in) and recompute badges (relayout) —
        // but must NOT re-fire the scroll anchor, or a theme switch would jump the
        // user back to a stale pendingScrollAnchor left over from the last reload.
        let docSourceChanged = context.coordinator.lastSource != doc.source
        let sourceChanged =
            docSourceChanged || textColorChanged || linkBaseChanged || documentLinkPolicyChanged
        let highlightChanged = context.coordinator.lastHighlightColor != highlightColor
        let hiddenChanged = context.coordinator.lastHiddenAnnotationIDs != hiddenAnnotationIDs
        if sourceChanged {
            let attr = attributedString(for: doc)
            // Task 5: apply highlight backgrounds BEFORE setting on the text storage.
            // applyHighlights mutates attr in place — no characters inserted.
            // Always wrap in a fresh NSMutableAttributedString so coordinator.currentAttr
            // and the value we hand to textStorage are guaranteed to be the same instance.
            let mutableAttr = NSMutableAttributedString(attributedString: attr)
            MarkdownAttributedStringBuilder.applyHighlights(
                mutableAttr, highlightColor: highlightColor, resolvedIDs: doc.resolvedAnnotationIDs, hiddenIDs: hiddenAnnotationIDs)
            textView.textStorage?.setAttributedString(mutableAttr)
            // INT-687: a fresh storage carries no tailIndent — rewrap + resize now.
            context.coordinator.noteStorageReplaced()
            context.coordinator.lastSource = doc.source
            context.coordinator.lastTextColor = textColor
            context.coordinator.lastRelativeLinkBaseURL = relativeLinkBaseURL
            context.coordinator.lastAllowsDocumentLinks = allowsDocumentLinks
            context.coordinator.lastDoc = doc
            context.coordinator.currentAttr = mutableAttr

            // Task 7: source-anchored scroll — only on a real content reload, never on
            // a textColor-only restyle (which would re-apply a stale anchor).
            if docSourceChanged, let anchor = scrollAnchorOffset {
                DispatchQueue.main.async {
                    context.coordinator.scrollToSourceOffset(anchor)
                }
            }
        } else if highlightChanged || hiddenChanged {
            // Highlight color or resolved-filter changed — re-apply without
            // rebuilding the full attributed string.
            if let mutableAttr = context.coordinator.currentAttr {
                MarkdownAttributedStringBuilder.applyHighlights(
                    mutableAttr, highlightColor: highlightColor, resolvedIDs: doc.resolvedAnnotationIDs, hiddenIDs: hiddenAnnotationIDs)
                textView.textStorage?.setAttributedString(mutableAttr)
                // INT-687: this branch replaces the storage too (currentAttr has
                // no tailIndent baked in), so the prose would silently unwrap on
                // a highlight/filter toggle without a fresh rewrap pass here.
                context.coordinator.noteStorageReplaced()
            }
        }
        context.coordinator.lastHighlightColor = highlightColor
        context.coordinator.lastHiddenAnnotationIDs = hiddenAnnotationIDs
        // Fix 3: push finalization callback + mark-touch guard to coordinator every update.
        context.coordinator.onSelectionFinalized = onSelectionFinalized
        context.coordinator.selectionTouchesMark = selectionTouchesMark
        context.coordinator.onOpenDocumentLink = onOpenDocumentLink

        // Task 7: re-register the capture closure on every update pass.
        onRegisterScrollAnchorCapture?({ [weak coordinator = context.coordinator] in
            coordinator?.scrollAnchorSourceOffset()
        })

        // Task 5 + Bigfoot: reposition and update callbacks on the badge overlay.
        // The overlay autoresizes with the text view's bounds (it's a subview), so we
        // don't reset its frame here. Its space == the text view's flipped space.
        if let overlay = context.coordinator.badgeOverlay {
            overlay.onPillClicked = onPillClicked
            overlay.onAddPillClicked = onAddPillClicked

            // Recompute badge positions only when the text was re-laid-out this pass
            // (source/textColor rebuild or highlight re-apply — both setAttributedString).
            // A selection-only update doesn't move any glyphs, so skipping the full
            // ensureLayout pass here avoids forcing a whole-document layout per selection
            // event; the add-pill below still follows the selection on every update.
            // Fix (INT-562 Bug 2): after setAttributedString, TextKit 2 has scheduled but
            // not yet completed layout. glyphTrailingRectInTextView uses firstRect(for:),
            // which depends on finalized layout — if called too early it returns .zero and
            // the pill is skipped. Force a layout pass first so the pill positions are
            // correct, then dispatch an async recompute for layout that settles afterward.
            if (sourceChanged || highlightChanged || hiddenChanged), let attr = context.coordinator.currentAttr {
                // Guard the layout-manager unwrap: a `!` in the argument is evaluated
                // before `?.` can short-circuit, so a TextKit-1 fallback (nil layout
                // manager) would crash. Bind it once instead.
                if let layoutManager = textView.textLayoutManager {
                    layoutManager.ensureLayout(for: layoutManager.documentRange)
                }
                // Badge ordinals for VoiceOver ("Comment 2") come from the doc's
                // span-annotation order, matching the popover's display number.
                // One O(n) pass — displayNumber(for:) rescans per call, and a
                // loop of it went quadratic (review).
                overlay.updateBadges(
                    attr: attr,
                    textView: textView,
                    displayNumbers: Self.spanDisplayNumbers(in: doc),
                    hiddenIDs: hiddenAnnotationIDs
                )

                // Async pass: catches layout that completes after this SwiftUI update
                // cycle. Task @MainActor keeps actor isolation so capturing the
                // non-Sendable views is fine (they're held by the view tree for the
                // task's ~1-frame lifetime). Read attr and doc from the coordinator AT
                // FIRE TIME, not from schedule-time captures: a reload can swap the
                // text storage in between, and unioning mark ranges from a stale attr
                // against the new layout places pills on text that moved (review).
                let coordinator = context.coordinator
                Task { @MainActor in
                    guard let currentAttr = coordinator.currentAttr else { return }
                    overlay.updateBadges(
                        attr: currentAttr,
                        textView: textView,
                        displayNumbers: Self.spanDisplayNumbers(in: coordinator.lastDoc),
                        // From the coordinator, like attr/doc — a schedule-time
                        // capture could pair the newest document with an older
                        // visibility filter when updates land back-to-back.
                        hiddenIDs: coordinator.lastHiddenAnnotationIDs
                    )
                }
            }

            // Compute add pill position from the trailing edge of the current selection,
            // in text-view (== overlay) space. Suppressed when the selection overlaps an
            // existing mark, or when there is no selection / no window yet.
            // Also require the selection to map to a valid single-cell/single-block
            // source span. A cross-cell (or cross-block) drag is rejected by
            // sourceSpan → nil; without this guard the add pill would still appear and
            // then do nothing when clicked, since the compose flow has no span to wrap.
            let selRange = textView.selectedRange()
            let hasValidSpan: Bool = {
                guard selRange.length > 0, let doc = context.coordinator.lastDoc else { return false }
                let utf16 = selRange.location..<(selRange.location + selRange.length)
                return SelectionSourceMapping.sourceSpan(forSelectedUTF16: utf16, in: doc) != nil
            }()
            // window != nil: firstRect(forCharacterRange:) needs a materialized
            // window; without one the rect converts to nil anyway, so skip the
            // screen-coordinate round-trip on this hot idempotent path.
            if !selectionTouchesMark, hasValidSpan, textView.window != nil {
                let trailingRect = CommentBadgeOverlay.glyphTrailingRectInTextView(
                    lastCharOf: selRange, in: textView
                )
                overlay.updateAddPill(trailingRect: trailingRect)
            } else {
                overlay.updateAddPill(trailingRect: nil)
            }
        }
    }
}

extension MarkdownTextView {
    /// 1-based badge ordinals by document order among span annotations,
    /// matching the popover's display number.
    fileprivate static func spanDisplayNumbers(in doc: RenderedDocument?) -> [String: Int] {
        guard let doc else { return [:] }
        var numbers: [String: Int] = [:]
        var nextOrdinal = 1
        for annotation in doc.annotations where annotation.anchor == .span {
            numbers[annotation.id] = nextOrdinal
            nextOrdinal += 1
        }
        return numbers
    }
}

// MARK: - MarkdownTextViewCoordinator

@MainActor
final class MarkdownTextViewCoordinator: NSObject, NSTextViewDelegate {
    @Binding var selectedSourceSpan: Range<Int>?

    /// Cache to avoid rebuilding the attributed string on every SwiftUI pass.
    var lastSource: String? = nil
    var lastDoc: RenderedDocument? = nil
    var lastHighlightColor: NSColor? = nil
    var lastHiddenAnnotationIDs: Set<String> = []
    var lastTextColor: NSColor? = nil
    var lastRelativeLinkBaseURL: URL? = nil
    var lastAllowsDocumentLinks: Bool? = nil
    var currentAttr: NSMutableAttributedString? = nil

    // Task 5
    weak var textView: NSTextView? = nil
    weak var badgeOverlay: CommentBadgeOverlay? = nil

    // Fix 3 (INT-562): auto-present compose popover on finalized selection.
    var onSelectionFinalized: ((Range<Int>, NSRect, NSTextView) -> Void)? = nil
    var selectionTouchesMark: Bool = false

    // INT-748 PR2: document links inherit the host tab's terminal association.
    var onOpenDocumentLink: ((URL) -> Void)? = nil

    init(selectedSourceSpan: Binding<Range<Int>?>) {
        self._selectedSourceSpan = selectedSourceSpan
    }

    // MARK: - Wide-table overflow (INT-687)

    /// Wrap width last applied to prose paragraphs. Nil forces a full pass —
    /// set whenever the text storage is replaced, because a fresh storage's
    /// paragraph styles carry no `tailIndent`.
    private var lastProseWrapWidth: CGFloat? = nil
    private var geometryPassScheduled = false

    /// Call after every `textStorage.setAttributedString`: rewraps prose and
    /// resizes the text view for the new content.
    func noteStorageReplaced() {
        lastProseWrapWidth = nil
        updateDocumentGeometry()
    }

    @objc func clipViewFrameDidChange(_ notification: Notification) {
        // Coalesce to the next runloop turn: clip frames also change as a
        // layout side-effect (scroller show/hide), and mutating textStorage
        // inside a layout pass would be reentrant. The hop also batches a
        // live-resize burst of frame changes into one geometry pass.
        guard !geometryPassScheduled else { return }
        geometryPassScheduled = true
        // RunLoop.perform, not DispatchQueue.main.async: identical next-turn
        // main-thread semantics, but runloop blocks also drain inside nested
        // runloop spins (live window-resize tracking via .common, and the
        // headless test harness), where queued main-queue blocks would starve
        // behind the block that is currently running.
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            guard let self else { return }
            // Reset AFTER the pass: setFrameSize inside it can synchronously
            // re-post frameDidChange (legacy scroller show/hide reclaims clip
            // width), and re-arming on that self-induced notification would
            // ping-pong between two wrap widths forever at the scroller
            // threshold. Swallowing it is safe — the pass just ran against the
            // final clip geometry of this runloop turn.
            self.updateDocumentGeometry()
            self.geometryPassScheduled = false
        }
    }

    /// INT-687 wide-table overflow. The text container is infinite in both
    /// axes; prose wraps to the pane via per-paragraph `tailIndent` while
    /// table rows run to their natural tab-stop width. The text view's frame
    /// is then computed from actual layout usage — `max(clip width, widest
    /// line)` — so a wide table widens the document (horizontal scroller
    /// appears) and its removal shrinks it back. Nothing self-sizes, so
    /// repeated clip resizes converge in a single pass.
    func updateDocumentGeometry() {
        guard let textView,
            let scrollView = textView.enclosingScrollView,
            let layoutManager = textView.textLayoutManager,
            let storage = textView.textStorage
        else { return }
        let clip = scrollView.contentView
        // The wrap width derives from the SCROLL VIEW frame, not the clip:
        // clip width shrinks when a legacy vertical scroller appears, and the
        // rewrap itself changes document height (and therefore scroller
        // visibility) — deriving from the clip would make wrap width a
        // function of its own output and oscillate at the threshold. With a
        // stable basis the pass is a converging function of pane size; the
        // legacy allowance is reserved unconditionally so short documents
        // wrap a scroller's-width narrow rather than flicker.
        let scrollerAllowance: CGFloat =
            scrollView.scrollerStyle == .legacy
            ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
        let wrapBasis = scrollView.frame.width - scrollerAllowance
        // A pass that changed no paragraph style cannot move any glyph, so
        // skip the full-document layout + measurement (a height-only resize
        // lands here every frame; forcing whole-doc layout would defeat
        // TextKit 2's incremental laziness on large documents).
        guard applyProseWrapWidth(to: storage, in: textView, clipWidth: wrapBasis) else {
            return
        }
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        let usage = layoutManager.usageBoundsForTextContainer
        let inset = textView.textContainerInset
        let size = NSSize(
            width: max(clip.bounds.width, usage.maxX + inset.width * 2),
            height: usage.maxY + inset.height * 2
        )
        if textView.frame.size != size {
            textView.setFrameSize(size)
        }
    }

    /// Stamps `tailIndent` on every non-table paragraph so prose (including
    /// code blocks — their wrap behavior is unchanged from the width-tracking
    /// era) breaks at the pane edge inside the infinite container. Table-row
    /// paragraphs are left alone: their natural width IS the overflow.
    /// Returns whether anything could have changed (wrap width moved or the
    /// storage is fresh); false means no glyph moved and callers can skip
    /// re-measuring.
    private func applyProseWrapWidth(
        to storage: NSTextStorage, in textView: NSTextView, clipWidth: CGFloat
    ) -> Bool {
        // Floor of 80pt: at sliver pane widths the computed value would go
        // non-positive, and a tailIndent ≤ 0 means "distance from the trailing
        // margin" — the infinite container edge, i.e. no wrapping at all.
        let width = max(clipWidth - textView.textContainerInset.width * 2, 80)
        guard width != lastProseWrapWidth else { return false }
        lastProseWrapWidth = width
        // Empty storage has no paragraphs to stamp but still needs measuring:
        // a wide document replaced by an empty one must shrink the frame back,
        // and `lastProseWrapWidth == nil` (fresh storage) reaches here even
        // when the width itself didn't move.
        guard storage.length > 0 else { return true }

        let ns = storage.string as NSString
        storage.beginEditing()
        var location = 0
        while location < ns.length {
            let paragraph = ns.paragraphRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(paragraph)
            guard paragraph.length > 0 else { break }
            // Check the whole paragraph for grid membership: a row can open
            // with a synthetic separator run that carries no grid attribute.
            var isTableRow = false
            storage.enumerateAttribute(.tableCellGrid, in: paragraph, options: []) { value, _, stop in
                if value != nil {
                    isTableRow = true
                    stop.pointee = true
                }
            }
            if isTableRow { continue }
            let existing =
                storage.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil)
                as? NSParagraphStyle
            if existing?.tailIndent == width { continue }
            // Copy-on-write: preserve whatever styling the paragraph already
            // carries and change only the wrap width.
            let style =
                (existing?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            style.tailIndent = width
            storage.addAttribute(.paragraphStyle, value: style, range: paragraph)
        }
        storage.endEditing()
        return true
    }

    /// Called by `SelectionAwareTextView.mouseDown(with:)` after `super.mouseDown`'s
    /// internal tracking loop has finished (and the drag-selection is fully committed).
    /// Reads the now-stable `selectedRange()`, maps it to a source span, and fires
    /// `onSelectionFinalized` if the span doesn't touch an existing mark.
    ///
    /// Fix 1 (INT-562): we now reach here via `mouseDown` rather than `mouseUp`.
    /// NSTextView runs its drag-tracking loop entirely inside `mouseDown`, so
    /// `super.mouseDown` blocks until mouse-up. By the time it returns the selection
    /// is committed. The old `mouseUp` override was frequently never called for
    /// drag-selections because AppKit's internal tracking loop consumed the event.
    ///
    /// Fix 2 (INT-562): removed the early `guard !selectionTouchesMark` check. The
    /// `selectionTouchesMark` binding is pushed from SwiftUI and can lag behind by one
    /// update cycle — a fresh drag that doesn't touch any mark could still read a
    /// stale `true`. Instead we read the range, compute the span, and gate on the
    /// accurate, span-based `spanTouchesExistingMark` check only.
    @MainActor
    func handleSelectionFinished(in textView: NSTextView) {
        let range = textView.selectedRange()
        guard range.length > 0, let doc = lastDoc else { return }
        let utf16Range = range.location..<(range.location + range.length)
        guard let span = SelectionSourceMapping.sourceSpan(forSelectedUTF16: utf16Range, in: doc) else { return }
        // Use the accurate span-based mark check — don't rely on the potentially-lagging binding.
        if SelectionSourceMapping.spanTouchesExistingMark(span, in: doc) { return }
        // Fix 3 (INT-562): ensure layout before computing the trailing rect so
        // glyphTrailingRectInTextView doesn't return nil on a freshly-laid-out doc.
        if let layoutManager = textView.textLayoutManager {
            layoutManager.ensureLayout(for: layoutManager.documentRange)
        }
        // Compute trailing glyph rect for anchoring.
        let trailingRect: NSRect
        if let rect = CommentBadgeOverlay.glyphTrailingRectInTextView(lastCharOf: range, in: textView) {
            trailingRect = rect
        } else {
            // Fallback: anchor to the selection's visible bounding rect so the composer
            // still appears even when the layout manager can't return a precise glyph rect.
            let screenRect = textView.firstRect(forCharacterRange: range, actualRange: nil)
            guard
                let textViewRect = CommentBadgeOverlay.textViewRect(
                    fromScreenRect: screenRect, in: textView
                )
            else { return }
            trailingRect = textViewRect
        }
        onSelectionFinalized?(span, trailingRect, textView)
    }

    // MARK: - Selection

    @MainActor
    func textViewDidChangeSelection(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView else { return }
        let range = textView.selectedRange()
        guard range.length > 0, let doc = lastDoc else {
            selectedSourceSpan = nil
            return
        }
        let utf16Range = range.location..<(range.location + range.length)
        selectedSourceSpan = SelectionSourceMapping.sourceSpan(forSelectedUTF16: utf16Range, in: doc)
    }

    // MARK: - Link clicks

    /// Routes a clicked link through `MarkdownLinkRouting`.
    ///
    /// `.document(url)` — opens via `onOpenDocumentLink` so the new tab inherits
    /// this document's terminal association (INT-748 PR2); falls back to the
    /// static `GhosttyRuntime.openDocumentHandler` path when unset.
    ///
    /// `.external(url)` — routes through `GhosttyRuntime.openURL`, which runs the
    /// full `URLClassifier` + block-confirm modal pipeline.
    ///
    /// Returning `true` suppresses NSTextView's default `NSWorkspace.open`.
    @MainActor
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:)) else {
            return true
        }
        switch MarkdownLinkRouting.route(url) {
        case .document(let docURL):
            if let onOpenDocumentLink {
                onOpenDocumentLink(docURL)
            } else {
                GhosttyRuntime.openURL(docURL)
            }
        case .external(let extURL):
            GhosttyRuntime.openURL(extURL)
        }
        return true
    }

    // MARK: - Scroll anchor (Task 7)

    /// Reads the UTF-8 source offset of the top visible glyph in the scroll view.
    func scrollAnchorSourceOffset() -> Int? {
        guard let textView,
            let scrollView = textView.enclosingScrollView,
            let attr = currentAttr,
            attr.length > 0
        else { return nil }

        let clipBounds = scrollView.contentView.bounds
        let topY = clipBounds.minY
        guard topY > 1 else { return nil }

        guard let layoutManager = textView.textLayoutManager,
            let contentStorage = textView.textContentStorage
        else { return nil }

        let inset = textView.textContainerInset
        let topInContainer = topY - inset.height

        var foundUTF16: Int? = nil
        layoutManager.enumerateTextLayoutFragments(
            from: layoutManager.documentRange.location,
            options: [.ensuresLayout]
        ) { fragment in
            let fragFrame = fragment.layoutFragmentFrame
            guard fragFrame.maxY > topInContainer else { return true }
            for lineFragment in fragment.textLineFragments {
                let lineFrame = lineFragment.typographicBounds.offsetBy(
                    dx: fragFrame.origin.x, dy: fragFrame.origin.y
                )
                guard lineFrame.maxY > topInContainer else { continue }
                let localPoint = NSPoint(x: 0, y: max(0, topInContainer - fragFrame.origin.y))
                let lineIdx = lineFragment.characterIndex(for: localPoint)
                let absOffset = contentStorage.offset(
                    from: contentStorage.documentRange.location,
                    to: fragment.rangeInElement.location
                )
                foundUTF16 = absOffset + lineIdx
                return false
            }
            return false
        }

        guard let utf16Idx = foundUTF16, utf16Idx < attr.length,
            let doc = lastDoc
        else { return nil }
        // INT-567: intra-run precise mapping instead of the old run-start-only
        // .sourceOffset attribute — a glyph halfway through a long paragraph
        // anchors to its own byte offset, not the paragraph start.
        return SelectionSourceMapping.sourceOffset(forRenderedUTF16: utf16Idx, in: doc)
    }

    /// Scrolls the text view so the line containing `sourceOffset` is at the top.
    func scrollToSourceOffset(_ targetOffset: Int) {
        guard let textView,
            let attr = currentAttr,
            attr.length > 0,
            let doc = lastDoc
        else { return }

        guard
            let mapped = SelectionSourceMapping.renderedUTF16Offset(
                forSourceOffset: targetOffset, in: doc
            )
        else { return }
        // The preceding-run fallback can return the rendered end of the last run
        // (== attr.length); clamp so the location/fragment lookup below stays valid.
        let idx = min(mapped, attr.length - 1)

        guard let layoutManager = textView.textLayoutManager,
            let contentStorage = textView.textContentStorage
        else { return }

        guard
            let location = contentStorage.location(
                contentStorage.documentRange.location,
                offsetBy: idx
            )
        else { return }

        // INT-567: a TextKit 2 layout fragment spans a whole paragraph, so
        // fragment.minY alone would restore to the paragraph start no matter how
        // precise the byte offset is. Descend to the text LINE fragment that
        // contains the mapped index — the mirror of the capture-side line walk
        // in scrollAnchorSourceOffset().
        var targetY: CGFloat? = nil
        layoutManager.enumerateTextLayoutFragments(
            from: location,
            options: [.ensuresLayout]
        ) { fragment in
            let fragFrame = fragment.layoutFragmentFrame
            targetY = fragFrame.minY
            let fragStart = contentStorage.offset(
                from: contentStorage.documentRange.location,
                to: fragment.rangeInElement.location
            )
            let localIdx = idx - fragStart
            for lineFragment in fragment.textLineFragments
            where NSLocationInRange(localIdx, lineFragment.characterRange) {
                targetY = fragFrame.origin.y + lineFragment.typographicBounds.minY
                break
            }
            return false
        }

        guard let y = targetY else { return }

        let inset = textView.textContainerInset
        let scrollY = max(0, y + inset.height - 4)
        // Preserve the horizontal position: the source anchor is a vertical
        // concept, and since INT-687 wide tables give the document a real
        // horizontal range — snapping x to 0 on every reload would yank a
        // user off the column they were inspecting. The clip view clamps the
        // carried-over x if the new content is narrower.
        let currentX = textView.enclosingScrollView?.contentView.bounds.origin.x ?? 0
        textView.scroll(NSPoint(x: currentX, y: scrollY))
    }

}
