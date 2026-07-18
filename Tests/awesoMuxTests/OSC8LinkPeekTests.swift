import Foundation
import Testing
@testable import awesoMux

// INT-453: the peek preview must never disagree with what a click would open,
// and must never fire for links the click path routes to the block-confirm
// modal. Both properties reduce to `OSC8LinkPeek.previewURL` returning a URL
// only for `.openDirect` classifications — test that gate directly, plus the
// modifier-driven trigger and the anchor geometry.
@Suite struct OSC8LinkPeekTests {
    // MARK: previewURL — the safety gate

    @Test func previewsPlainDirectOpenURLs() {
        #expect(OSC8LinkPeek.previewURL(forLink: "https://example.com")?.absoluteString == "https://example.com")
        #expect(OSC8LinkPeek.previewURL(forLink: "http://example.com/path")?.absoluteString == "http://example.com/path")
        // Bare mailto with no attacker-controllable params is a direct open.
        #expect(OSC8LinkPeek.previewURL(forLink: "mailto:someone@example.com") != nil)
    }

    @Test func doesNotPreviewBlockConfirmURLs() {
        // embedded userinfo — classic host-disguise phishing.
        #expect(OSC8LinkPeek.previewURL(forLink: "https://github.com@evil.example/") == nil)
        // non-ASCII / punycode host — block-confirm handles these; peek would be
        // redundant (and this is why the "punycode warning in popover" line is
        // unreachable under openDirect-only gating).
        #expect(OSC8LinkPeek.previewURL(forLink: "https://xn--e1afmkfd.example/") == nil)
        // mailto with prefill params.
        #expect(OSC8LinkPeek.previewURL(forLink: "mailto:a@b.com?subject=hi&body=x") == nil)
    }

    @Test func doesNotPreviewNonExternalOrEmptyLinks() {
        #expect(OSC8LinkPeek.previewURL(forLink: nil) == nil)
        #expect(OSC8LinkPeek.previewURL(forLink: "") == nil)
        // Disallowed scheme.
        #expect(OSC8LinkPeek.previewURL(forLink: "javascript:alert(1)") == nil)
        // file:// markdown resolves to a file URL, which classifies as a
        // disallowed scheme (block-confirm) — routed to the document pane on
        // click, never an external open, so no external-URL peek.
        #expect(OSC8LinkPeek.previewURL(forLink: "file:///tmp/notes.md") == nil)
    }

    // MARK: trigger — modifier vs dwell

    @Test func commandHeldTriggersImmediate() {
        #expect(
            OSC8LinkPeek.trigger(forLink: "https://example.com", commandHeld: true)
                == .immediate(URL(string: "https://example.com")!))
    }

    @Test func plainHoverTriggersDelayed() {
        #expect(
            OSC8LinkPeek.trigger(forLink: "https://example.com", commandHeld: false)
                == .delayed(URL(string: "https://example.com")!))
    }

    @Test func unpeekableLinkNeverTriggers() {
        #expect(OSC8LinkPeek.trigger(forLink: "https://github.com@evil.example/", commandHeld: true) == .none)
        #expect(OSC8LinkPeek.trigger(forLink: nil, commandHeld: true) == .none)
    }

    // MARK: plain-click activation — string init parity

    @Test func stringInitMatchesResolvePath() {
        // Plain-click activation feeds the hovered link string back through
        // OpenURLAction; its resolution must be identical to the C-struct path
        // (both funnel into OpenURLAction.resolve).
        #expect(OpenURLAction("https://example.com").url == OpenURLAction.resolve("https://example.com"))
        #expect(OpenURLAction("https://xn--pypal-4ve.example/").url != nil)
        #expect(OpenURLAction("javascript:alert(1)").url == nil)
    }

    // MARK: anchorRect — geometry

    @Test func anchorRectIsCellTallAtThePoint() {
        let rect = OSC8LinkPeek.anchorRect(atViewLocalPoint: CGPoint(x: 10, y: 20), cellHeight: 15)
        #expect(rect == NSRect(x: 10, y: 20, width: 1, height: 15))
    }

    @Test func anchorRectClampsDegenerateCellHeight() {
        // cellSize can be .zero before the first surface metrics arrive.
        let rect = OSC8LinkPeek.anchorRect(atViewLocalPoint: .zero, cellHeight: 0)
        #expect(rect.height == 1)
    }
}
