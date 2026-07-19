import AppKit
import Testing

@testable import DesignSystem

/// Pins the CA-animation lifecycle in `SpinnerView`: the rotation must arm
/// only while attached to a window AND spinning, survive detach/reattach
/// (Core Animation strips animations on layer-tree exit), and honor the
/// Reduce Motion flag in both directions.
@Suite("ThinkingSpinner animation lifecycle")
@MainActor
struct ThinkingSpinnerTests {
    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        // Over-release crashes silently on close() otherwise (see project
        // test-window precedent).
        window.isReleasedWhenClosed = false
        return window
    }

    @Test("no animation before window attach, armed after")
    func armsOnWindowAttach() {
        let view = SpinnerView()
        view.setSpinning(true)
        #expect(!view.isSpinAnimationActive)

        let window = makeWindow()
        defer { window.close() }
        window.contentView?.addSubview(view)
        #expect(view.isSpinAnimationActive)
    }

    @Test("detach clears the animation, reattach re-arms it")
    func reArmsAcrossDetachReattach() {
        let view = SpinnerView()
        view.setSpinning(true)
        let window = makeWindow()
        defer { window.close() }
        window.contentView?.addSubview(view)
        #expect(view.isSpinAnimationActive)

        view.removeFromSuperview()
        #expect(!view.isSpinAnimationActive)

        window.contentView?.addSubview(view)
        #expect(view.isSpinAnimationActive)
    }

    @Test("reduce-motion stop and restart while attached")
    func spinningFlagTogglesAnimationWhileAttached() {
        let view = SpinnerView()
        view.setSpinning(true)
        let window = makeWindow()
        defer { window.close() }
        window.contentView?.addSubview(view)
        #expect(view.isSpinAnimationActive)

        view.setSpinning(false)
        #expect(!view.isSpinAnimationActive)

        view.setSpinning(true)
        #expect(view.isSpinAnimationActive)
    }

    @Test("reduce-motion state set before attach is honored on attach")
    func reducedMotionSurvivesAttach() {
        let view = SpinnerView()
        view.setSpinning(false)
        let window = makeWindow()
        defer { window.close() }
        window.contentView?.addSubview(view)
        #expect(!view.isSpinAnimationActive)
    }
}
