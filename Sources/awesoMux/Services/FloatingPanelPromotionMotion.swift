import Foundation

struct FloatingPanelPromotionMotion: Equatable, Sendable {
    let compressDelay: Duration
    let tabInsertionDelay: Duration
    let dismissDelay: Duration
    let selectionDelay: Duration
    let settleDelay: Duration
    let tabInsertionDuration: TimeInterval
    let pulseInDuration: TimeInterval
    let pulseOutDuration: TimeInterval

    static let standard = FloatingPanelPromotionMotion(
        compressDelay: .milliseconds(80),
        tabInsertionDelay: .milliseconds(160),
        dismissDelay: .milliseconds(200),
        selectionDelay: .milliseconds(300),
        settleDelay: .milliseconds(900),
        tabInsertionDuration: 0.2,
        pulseInDuration: 0.3,
        pulseOutDuration: 0.6
    )

    static let reduced = FloatingPanelPromotionMotion(
        compressDelay: .zero,
        tabInsertionDelay: .zero,
        dismissDelay: .zero,
        selectionDelay: .zero,
        settleDelay: .zero,
        tabInsertionDuration: 0,
        pulseInDuration: 0,
        pulseOutDuration: 0
    )

    static func resolved(reduceMotion: Bool) -> FloatingPanelPromotionMotion {
        let motion = reduceMotion ? reduced : standard
        // Delays are cumulative-from-t0; the controller sleeps on the deltas
        // between phases. Non-monotonic values would make a delta go negative,
        // and the sleep helper silently skips negatives — collapsing that phase
        // to t0 with no error. Guard the invariant where it must hold.
        assert(
            motion.compressDelay <= motion.tabInsertionDelay
                && motion.tabInsertionDelay <= motion.dismissDelay
                && motion.dismissDelay <= motion.selectionDelay
                && motion.selectionDelay <= motion.settleDelay,
            "promotion delays must be cumulative-from-t0 and non-decreasing"
        )
        return motion
    }
}

enum FloatingPanelPromotionPhase: Equatable, Sendable {
    case idle
    case compressing
}
