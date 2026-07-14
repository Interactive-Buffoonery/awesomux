import AppKit
import AwesoMuxConfig
import QuartzCore
import Testing
@testable import awesoMux

@Suite("Sidebar overlay animator", .serialized)
@MainActor
struct SidebarOverlayAnimatorTests {
    private final class Driver {
        struct Request {
            let from: CGFloat
            let to: CGFloat
            let duration: TimeInterval
        }

        var presentationTranslation: CGFloat?
        var requests: [Request] = []
        var completions: [() -> Void] = []
    }

    @Test("left and right reveal from their physical edges")
    func mirroredTransforms() {
        #expect(SidebarOverlayAnimator.hiddenTranslation(width: 300, position: .left) == -300)
        #expect(SidebarOverlayAnimator.hiddenTranslation(width: 300, position: .right) == 300)
        #expect(SidebarOverlayAnimator.presentedTranslation == 0)
    }

    @Test("visible fraction maps width changes on both physical sides")
    func fractionMapping() {
        #expect(SidebarOverlayAnimator.visibleFraction(translationX: -225, hiddenTranslationX: -300) == 0.25)
        #expect(SidebarOverlayAnimator.translation(width: 60, position: .left, visibleFraction: 0.25) == -45)
        #expect(SidebarOverlayAnimator.translation(width: 300, position: .right, visibleFraction: 0.25) == 225)

        for position in [AppearanceConfig.SidebarPosition.left, .right] {
            for fraction: CGFloat in [0, 0.25, 0.5, 1] {
                for width: CGFloat in [60, 180, 300] {
                    let translation = SidebarOverlayAnimator.translation(
                        width: width, position: position, visibleFraction: fraction)
                    #expect(
                        SidebarOverlayAnimator.visibleFraction(
                            translationX: translation,
                            hiddenTranslationX: SidebarOverlayAnimator.hiddenTranslation(
                                width: width, position: position)) == fraction)
                }
            }
        }
        #expect(SidebarOverlayAnimator.visibleFraction(translationX: 1, hiddenTranslationX: 0) == 0)
        #expect(SidebarOverlayAnimator.visibleFraction(translationX: .infinity, hiddenTranslationX: -300) == 0)
    }

    @Test("reversal samples presentation and stale completion loses")
    func reversalUsesPresentationTransform() throws {
        let layer = CALayer()
        let driver = Driver()
        let animator = makeAnimator(layer: layer, driver: driver)
        var completed: [UInt] = []

        animator.setPresented(
            true, width: 300, position: .left, transition: .hover, reduceMotion: false
        ) { completed.append($0) }
        driver.presentationTranslation = -120
        animator.setPresented(
            false, width: 300, position: .left, transition: .hover, reduceMotion: false
        ) { completed.append($0) }

        #expect(driver.requests.last?.from == -120)
        driver.completions[0]()
        #expect(completed.isEmpty)
        #expect(animator.requestedPresentedForTesting == false)
        driver.completions[1]()
        #expect(completed.count == 1)
        #expect(layer.affineTransform().tx == -300)
    }

    @Test("same active intent does not restart and equal target settles immediately")
    func idempotence() {
        let layer = CALayer()
        let driver = Driver()
        let animator = makeAnimator(layer: layer, driver: driver)
        animator.setPresented(true, width: 300, position: .right, transition: .hover, reduceMotion: false) { _ in }
        animator.setPresented(true, width: 300, position: .right, transition: .hover, reduceMotion: false) { _ in }
        #expect(driver.requests.count == 1)
        driver.completions[0]()
        animator.setPresented(true, width: 300, position: .right, transition: .hover, reduceMotion: false) { _ in }
        #expect(driver.requests.count == 1)
    }

    @Test("hit testing fallback stays at animation origin before presentation exists")
    func preCommitFallback() {
        for position in [AppearanceConfig.SidebarPosition.left, .right] {
            let layer = CALayer()
            let driver = Driver()
            let animator = makeAnimator(layer: layer, driver: driver)
            animator.setPresented(
                true, width: 300, position: position, transition: .hover, reduceMotion: false
            ) { _ in }
            #expect(
                animator.currentTranslation
                    == SidebarOverlayAnimator.hiddenTranslation(width: 300, position: position))
        }
    }

    @Test("Reduce Motion settles without an animation request")
    func reduceMotion() {
        let layer = CALayer()
        let driver = Driver()
        let animator = makeAnimator(layer: layer, driver: driver)
        var completions = 0
        animator.setPresented(true, width: 300, position: .left, transition: .hover, reduceMotion: true) { _ in
            completions += 1
        }
        #expect(driver.requests.isEmpty)
        #expect(completions == 1)
        #expect(layer.affineTransform().tx == 0)
    }

    @Test("resize preserves presentation fraction before restarting")
    func resizePreservesFraction() {
        let layer = CALayer()
        let driver = Driver()
        let animator = makeAnimator(layer: layer, driver: driver)
        animator.setPresented(
            true, width: 300, position: .left, transition: .hover, reduceMotion: false
        ) { _ in }
        driver.presentationTranslation = -225

        animator.reframe(
            fromWidth: 300,
            toWidth: 60,
            position: .left,
            transition: .hover,
            reduceMotion: false
        ) { _ in }

        #expect(driver.requests.last?.from == -45)
        #expect(driver.requests.last?.to == 0)
    }

    @Test("resize without a presentation layer uses the finite fallback on both sides")
    func noPresentationResize() {
        for position in [AppearanceConfig.SidebarPosition.left, .right] {
            let layer = CALayer()
            let driver = Driver()
            let animator = makeAnimator(layer: layer, driver: driver)
            animator.setPresented(
                true, width: 300, position: position, transition: .hover, reduceMotion: false
            ) { _ in }
            animator.reframe(
                fromWidth: 300,
                toWidth: 60,
                position: position,
                transition: .hover,
                reduceMotion: false
            ) { _ in }
            #expect(
                driver.requests.last?.from
                    == SidebarOverlayAnimator.hiddenTranslation(width: 60, position: position))
        }
    }

    @Test("right resize restarts from its fraction-mapped translation")
    func rightResizeRestart() {
        let layer = CALayer()
        let driver = Driver()
        let animator = makeAnimator(layer: layer, driver: driver)
        animator.setPresented(
            true, width: 300, position: .right, transition: .hover, reduceMotion: false
        ) { _ in }
        driver.presentationTranslation = 225
        animator.reframe(
            fromWidth: 300,
            toWidth: 60,
            position: .right,
            transition: .hover,
            reduceMotion: false
        ) { _ in }
        #expect(driver.requests.last?.from == 45)
        #expect(driver.requests.last?.to == 0)
    }

    @Test("hover uses the fixed duration and ease-in-out timing")
    func fixedHoverContract() {
        #expect(driverDurationForHover() == 0.140)
        #expect(SidebarOverlayAnimator.timingFunctionName == .easeInEaseOut)
    }

    private func driverDurationForHover() -> TimeInterval {
        let layer = CALayer()
        let driver = Driver()
        let animator = makeAnimator(layer: layer, driver: driver)
        animator.setPresented(
            true, width: 300, position: .left, transition: .hover, reduceMotion: false
        ) { _ in }
        return driver.requests[0].duration
    }

    private func makeAnimator(layer: CALayer, driver: Driver) -> SidebarOverlayAnimator {
        SidebarOverlayAnimator(
            layer: layer,
            presentationTranslation: { driver.presentationTranslation },
            animationRunner: { _, from, to, duration, completion in
                driver.requests.append(.init(from: from, to: to, duration: duration))
                driver.completions.append(completion)
            })
    }
}
