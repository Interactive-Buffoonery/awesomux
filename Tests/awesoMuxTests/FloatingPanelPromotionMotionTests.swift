import Foundation
import Testing
@testable import awesoMux

@Suite("Floating panel promotion motion")
struct FloatingPanelPromotionMotionTests {
    @Test("standard timing matches the animated handoff storyboard")
    func standardTimingMatchesStoryboard() {
        let motion = FloatingPanelPromotionMotion.resolved(reduceMotion: false)

        #expect(motion.compressDelay == .milliseconds(80))
        #expect(motion.tabInsertionDelay == .milliseconds(160))
        #expect(motion.dismissDelay == .milliseconds(200))
        #expect(motion.selectionDelay == .milliseconds(300))
        #expect(motion.settleDelay == .milliseconds(900))
        #expect(motion.tabInsertionDuration == 0.2)
        #expect(motion.pulseInDuration == 0.3)
        #expect(motion.pulseOutDuration == 0.6)
    }

    @Test("reduced motion swaps without delayed scale fade or slide")
    func reducedMotionSwapsWithoutDelayedMotion() {
        let motion = FloatingPanelPromotionMotion.resolved(reduceMotion: true)

        #expect(motion.compressDelay == .zero)
        #expect(motion.tabInsertionDelay == .zero)
        #expect(motion.dismissDelay == .zero)
        #expect(motion.selectionDelay == .zero)
        #expect(motion.settleDelay == .zero)
        #expect(motion.tabInsertionDuration == 0)
        #expect(motion.pulseInDuration == 0)
        #expect(motion.pulseOutDuration == 0)
    }
}
