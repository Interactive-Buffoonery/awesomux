import AppKit
import AwesoMuxCore
import SwiftUI

// MARK: - OSC 8 link peek decision + geometry (pure)

/// Pure logic for the OSC 8 hyperlink "peek" preview (INT-453): decide whether a
/// hovered link should surface a preview and where to anchor it. Kept free of
/// live-view state so the gate and anchor math are unit-testable, mirroring
/// `GhosttySurfaceNSView.viewMousePosition`.
enum OSC8LinkPeek {
    enum Trigger: Equatable {
        case none
        /// Show now (a modifier key is held).
        case immediate(URL)
        /// Show after the dwell interval.
        case delayed(URL)
    }

    /// Resolve + classify a hovered link exactly the way the click path does, so
    /// the peek can never disagree with what a click would open: `openURL` routes
    /// through `OpenURLAction.resolve` then `URLClassifier.classify`. Preview only
    /// for `.openDirect` — `.blockConfirm` decisions are handled by the existing
    /// modal (a preview would be redundant, per the issue), and `file:`/markdown
    /// document links resolve to a `file:` URL that classifies as
    /// `.disallowedScheme` (block-confirm) so they never peek either.
    static func previewURL(forLink link: String?) -> URL? {
        guard let link, let url = OpenURLAction.resolve(link) else {
            return nil
        }
        guard case .openDirect = URLClassifier.classify(url) else {
            return nil
        }
        return url
    }

    static func trigger(forLink link: String?, commandHeld: Bool) -> Trigger {
        guard let url = previewURL(forLink: link) else {
            return .none
        }
        return commandHeld ? .immediate(url) : .delayed(url)
    }

    /// A thin, cell-tall anchor rect at the cursor. libghostty exposes only the
    /// hovered link's URL string (`GHOSTTY_ACTION_MOUSE_OVER_LINK`), never its
    /// cell rectangle, so the preview anchors at the pointer. The point is
    /// view-local in AppKit's default bottom-left space (the surface view is not
    /// flipped), which is what `NSPopover.show(relativeTo:of:)` expects — no
    /// Y-flip. Pairing this rect with `preferredEdge: .maxY` puts the popover
    /// above the pointer so its body does not cover the cursor.
    static func anchorRect(atViewLocalPoint point: CGPoint, cellHeight: CGFloat) -> NSRect {
        NSRect(x: point.x, y: point.y, width: 1, height: max(cellHeight, 1))
    }
}

// MARK: - Peek popover presentation

extension GhosttySurfaceNSView {
    /// Plain-hover dwell before a peek appears. Command-hover shows immediately.
    static let linkPeekDwell: TimeInterval = 0.6
    /// Grace before a "cursor left the link" dismiss actually closes the popover.
    /// Absorbs the transient `mouseExited` a screen-edge-flipped popover can emit
    /// by covering the cursor; a re-entered same link cancels the pending dismiss.
    /// ponytail: drop the grace (dismiss inline) if live smoke shows it's unneeded.
    static let linkPeekDismissGrace: TimeInterval = 0.15

    /// Entry point from `updateMouseOverLink` (hover changed) — reads the live
    /// modifier state so a link hovered with ⌘ already down peeks instantly.
    func updateLinkPeek(for link: String?) {
        applyLinkPeekTrigger(
            OSC8LinkPeek.trigger(
                forLink: link,
                commandHeld: NSEvent.modifierFlags.contains(.command)
            ),
            link: link
        )
    }

    /// `flagsChanged` promotion: ⌘ pressed WHILE already resting on a link emits
    /// no new `updateMouseOverLink` (the callback dedups on unchanged URL), so the
    /// modifier trigger would never fire without this. Guarded like every other
    /// non-drag pointer path in the bridge: pointer actually over this view, no
    /// button held.
    func promoteLinkPeekForCommandIfHovering() {
        guard hasNoMouseButtonHeld, currentMousePositionInView() != nil else {
            return
        }
        applyLinkPeekTrigger(
            OSC8LinkPeek.trigger(forLink: mouseOverLink, commandHeld: true),
            link: mouseOverLink
        )
    }

    private func applyLinkPeekTrigger(_ trigger: OSC8LinkPeek.Trigger, link: String?) {
        linkPeekShowWorkItem?.cancel()
        linkPeekShowWorkItem = nil

        switch trigger {
        case .none:
            scheduleLinkPeekDismiss()

        case let .immediate(url):
            linkPeekDismissWorkItem?.cancel()
            linkPeekDismissWorkItem = nil
            showLinkPeek(url, link: link)

        case let .delayed(url):
            linkPeekDismissWorkItem?.cancel()
            linkPeekDismissWorkItem = nil
            guard let link, !isShowingLinkPeek(for: link) else {
                return
            }
            let work = DispatchWorkItem { [weak self] in
                // Re-validate at fire time: canceling a DispatchWorkItem can't stop
                // one already dequeued, so a moved-off / defocused / drag-started
                // view must not surface a stale preview.
                guard let self,
                    self.mouseOverLink == link,
                    self.window?.isKeyWindow == true,
                    self.hasNoMouseButtonHeld
                else { return }
                self.showLinkPeek(url, link: link)
            }
            linkPeekShowWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.linkPeekDwell, execute: work)
        }
    }

    private func isShowingLinkPeek(for link: String) -> Bool {
        peekedLink == link && linkPeekPopover?.isShown == true
    }

    private func showLinkPeek(_ url: URL, link: String?) {
        guard let window, window.isKeyWindow, hasNoMouseButtonHeld else {
            return
        }
        if let link, isShowingLinkPeek(for: link) {
            return
        }
        // Replace any existing (different-link, or transient-auto-closed) popover.
        dismissLinkPeek()

        let anchorPoint = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let anchor = OSC8LinkPeek.anchorRect(
            atViewLocalPoint: anchorPoint,
            cellHeight: cellSize.height
        )

        let popover = NSPopover()
        // .transient auto-dismisses on any interaction outside the popover, so a
        // click on the link (outside the popover) still reaches libghostty and
        // opens through the existing OPEN_URL gate; a click elsewhere just closes.
        popover.behavior = .transient
        // Delegate clears our state when the popover closes WITHOUT going through
        // `dismissLinkPeek` (transient outside-click, Esc). Without it the stored
        // popover + hosting graph linger and a stationary hover on the same link
        // can never re-peek — `updateMouseOverLink` dedups the unchanged URL, so
        // no event would replace the stale reference (review finding).
        popover.delegate = self
        let hosting = NSHostingController(rootView: OSC8LinkPeekView(urlText: url.absoluteString))
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        popover.show(relativeTo: anchor, of: self, preferredEdge: .maxY)

        linkPeekPopover = popover
        peekedLink = link

        // The content carries an accessibilityLabel; announce once per shown link
        // (peekedLink dedups) for VoiceOver users tracking with a pointer.
        TerminalAccessibilityAnnouncer.announce(
            String(
                localized: "Link preview: \(url.absoluteString)",
                comment: "VoiceOver announcement when a hovered hyperlink preview popover appears"
            )
        )
    }

    /// Debounced "cursor left the link" dismiss. No-op when nothing is pending or
    /// shown so idle hovers stay cheap. Not `private`: `mouseExited` (input
    /// bridge, separate file) must route through the same grace — near the top
    /// screen edge AppKit flips a `.maxY` popover below the anchor where it
    /// covers the cursor and fires a transient `mouseExited`; an immediate
    /// dismiss there closes the peek the instant it opens (review finding).
    func scheduleLinkPeekDismiss() {
        guard linkPeekPopover != nil else {
            peekedLink = nil
            return
        }
        // A popover flipped below a top-edge anchor sits under the pointer: the
        // resulting mouseExited AND the (-1,-1)-induced nil hover callback both
        // land here, and a grace alone would still close the peek 0.15s after it
        // opened. Pointer resting on the preview keeps it open (standard tooltip
        // semantics); click, scroll, and detach still dismiss unconditionally via
        // `dismissLinkPeek`. Checked again at fire time below for a pointer that
        // moved onto the popover mid-grace.
        guard !pointerIsOverLinkPeekPopover else {
            return
        }
        linkPeekDismissWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.pointerIsOverLinkPeekPopover else { return }
            self.dismissLinkPeek()
        }
        linkPeekDismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.linkPeekDismissGrace, execute: work)
    }

    private var pointerIsOverLinkPeekPopover: Bool {
        guard let popover = linkPeekPopover, popover.isShown,
            let popoverWindow = popover.contentViewController?.view.window
        else {
            return false
        }
        // Both in screen coordinates.
        return popoverWindow.frame.contains(NSEvent.mouseLocation)
    }

    /// Cancel any pending work and close the popover. Safe to call when nothing is
    /// showing (mouseDown / scroll / exit / window detach all funnel here). No
    /// first-responder restore: the preview content is non-interactive and cannot
    /// take first responder, so it never displaces the terminal.
    func dismissLinkPeek() {
        linkPeekShowWorkItem?.cancel()
        linkPeekShowWorkItem = nil
        linkPeekDismissWorkItem?.cancel()
        linkPeekDismissWorkItem = nil
        peekedLink = nil
        guard let popover = linkPeekPopover else {
            return
        }
        linkPeekPopover = nil
        popover.performClose(nil)
    }
}

// MARK: - Peek popover delegate

extension GhosttySurfaceNSView: NSPopoverDelegate {
    /// Reached only by closes that bypass `dismissLinkPeek` (transient
    /// outside-click, Esc): the dismiss path nils `linkPeekPopover` before
    /// `performClose`, so its own close fails the identity check here.
    func popoverDidClose(_ notification: Notification) {
        guard let popover = notification.object as? NSPopover,
            popover === linkPeekPopover
        else {
            return
        }
        linkPeekPopover = nil
        peekedLink = nil
        linkPeekDismissWorkItem?.cancel()
        linkPeekDismissWorkItem = nil
    }
}

// MARK: - Peek content

/// Read-only OSC 8 link preview. No focusable controls — a hover hint must never
/// steal first responder or key focus from the terminal.
struct OSC8LinkPeekView: View {
    let urlText: String

    var body: some View {
        Text(urlText)
            .font(.system(.body, design: .monospaced))
            .lineLimit(3)
            .truncationMode(.middle)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: 480, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement()
            .accessibilityLabel(
                Text(
                    String(
                        localized: "Link preview: \(urlText)",
                        comment: "VoiceOver label for the hovered hyperlink preview popover"
                    )
                )
            )
    }
}
