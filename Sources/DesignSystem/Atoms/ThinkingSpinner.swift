import AppKit
import SwiftUI

/// Compositor-only "thinking" spinner.
///
/// The SwiftUI `repeatForever` rotation this replaces emitted a main-thread
/// transaction on every animation frame, each one re-querying AppKit platform
/// hosts' `layoutTraits`/`fittingSize` (~30 recursive constraint-engine frames
/// per tick). While any pane was thinking that burned ~10-12% of a core
/// (issue #146). A `CABasicAnimation` runs entirely in the render server, so
/// the rotation costs zero main-thread per-frame work.
struct ThinkingSpinner: NSViewRepresentable {
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> SpinnerView {
        let view = SpinnerView()
        view.lastColor = color
        view.strokeColor = NSColor(color)
        view.setSpinning(!reduceMotion)
        return view
    }

    func updateNSView(_ nsView: SpinnerView, context: Context) {
        // Skip the NSColor re-bridge + needsDisplay when the color hasn't
        // moved — updateNSView fires on every ancestor diff pass, not just
        // when this view's inputs change.
        if nsView.lastColor != color {
            nsView.lastColor = color
            nsView.strokeColor = NSColor(color)
        }
        // Live-reactive to RM toggling, matching the SwiftUI original's
        // `.onChange(of: reduceMotion)`.
        nsView.setSpinning(!reduceMotion)
    }

    // Load-bearing: the whole issue #146 bug family is fitting-size constraint
    // walks, so the spinner must never be asked to auto-invent its size.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SpinnerView, context: Context) -> CGSize? {
        CGSize(width: 10, height: 10)
    }
}

final class SpinnerView: NSView {
    // Replaces the deleted 0.9s linear thinking-spin animation token.
    private static let revolutionDuration: CFTimeInterval = 0.9
    private static let animationKey = "spin"

    private let shape = CAShapeLayer()
    private var spinning = false

    /// The SwiftUI color last pushed by `updateNSView`, so unchanged colors
    /// skip the NSColor bridge entirely.
    var lastColor: Color?

    var strokeColor: NSColor = .clear {
        didSet { needsDisplay = true }  // updateLayer applies it appearance-correctly
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        let box = CGRect(x: 0, y: 0, width: 10, height: 10)
        shape.frame = box
        shape.path = CGPath(ellipseIn: box, transform: nil)
        shape.fillColor = nil
        shape.lineWidth = 1.6
        shape.lineCap = .round
        // Matches SwiftUI `Circle().trim(from: 0.2, to: 1)`.
        shape.strokeStart = 0.2
        shape.strokeEnd = 1.0
        layer?.addSublayer(shape)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize { NSSize(width: 10, height: 10) }
    override var wantsUpdateLayer: Bool { true }

    // Decorative, like the `.waiting` pause glyph one switch-arm over: a bare
    // bridged NSView self-exposes to VoiceOver as an unlabeled stop inside
    // combining containers (AwPill, roster headers). State comes from the
    // labeled container. Same pattern as CommentBadgeOverlay.
    override func isAccessibilityElement() -> Bool { false }

    override func updateLayer() {
        // Resolve the token/override color against the current effective
        // appearance so light/dark switches recolor the arc.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            shape.strokeColor = strokeColor.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// Test seam: whether the rotation animation is currently attached.
    var isSpinAnimationActive: Bool { shape.animation(forKey: Self.animationKey) != nil }

    func setSpinning(_ shouldSpin: Bool) {
        spinning = shouldSpin
        applyAnimation()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateContentsScale()
        // AppKit can recreate the backing layer (screen/color-space changes,
        // popover hosting); a once-at-init sublayer add would leave the shape
        // orphaned and the spinner silently blank.
        if let layer, shape.superlayer !== layer {
            layer.addSublayer(shape)
        }
        // Core Animation strips a layer's animations when it leaves the layer
        // tree (tab switch/detach); re-arm so the spinner survives reattach.
        // The re-armed spin restarts at 0° — a deliberate tradeoff: seeding
        // the presentation-layer angle isn't worth it for a 10×10 glyph
        // mid-window-drag.
        applyAnimation()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateContentsScale()
    }

    private func updateContentsScale() {
        // AppKit manages the backing layer's contentsScale but not manually
        // added sublayers — without this the arc rasterizes at 1x on Retina.
        shape.contentsScale = window?.backingScaleFactor ?? 2
    }

    private func applyAnimation() {
        guard spinning, window != nil else {
            shape.removeAnimation(forKey: Self.animationKey)
            return
        }
        guard shape.animation(forKey: Self.animationKey) == nil else { return }
        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = 0
        // Negative on the non-flipped (y-up) macOS layer = clockwise, matching
        // the SwiftUI `.rotationEffect(.degrees(360))` this replaced.
        rotation.toValue = -2 * Double.pi
        rotation.duration = Self.revolutionDuration
        rotation.repeatCount = .infinity
        shape.add(rotation, forKey: Self.animationKey)
    }
}
