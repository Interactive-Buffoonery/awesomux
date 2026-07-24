import AwesoMuxCore
import CoreGraphics
import Testing
@testable import awesoMux

@Suite("Surface resize update policy")
struct SurfaceResizeUpdatePolicyTests {
    @Test("first geometry applies immediately, even mid-live-resize or settle")
    func firstGeometryAppliesImmediately() {
        let state = surfaceState(width: 800, height: 600)

        // A freshly created surface (nil lastApplied) must never be deferred —
        // this is the cold-launch guarantee that protects fastfetch sizing
        // (INT-289). True regardless of live-resize OR divider-settle state.
        for live in [false, true] {
            for settling in [false, true] {
                #expect(
                    SurfaceResizeUpdatePolicy.decision(
                        lastApplied: nil, next: state,
                        isInLiveResize: live, isSettlingDividerAnimation: settling)
                        == .applyImmediately
                )
            }
        }
    }

    @Test("identical geometry is skipped")
    func identicalGeometrySkips() {
        let state = surfaceState(width: 800, height: 600)

        #expect(
            SurfaceResizeUpdatePolicy.decision(
                lastApplied: state, next: state,
                isInLiveResize: true, isSettlingDividerAnimation: false)
                == .skip
        )
    }

    @Test("same-scale size changes defer during a live resize")
    func sameScaleSizeChangesDeferDuringLiveResize() {
        let current = surfaceState(width: 800, height: 600)
        let next = surfaceState(width: 900, height: 640)

        #expect(
            SurfaceResizeUpdatePolicy.decision(
                lastApplied: current, next: next,
                isInLiveResize: true, isSettlingDividerAnimation: false)
                == .deferUntilSettled
        )
    }

    @Test("same-scale size changes defer during a divider-settle animation")
    func sameScaleSizeChangesDeferDuringSettleAnimation() {
        let current = surfaceState(width: 800, height: 600)
        let next = surfaceState(width: 900, height: 640)

        // The eased divider settle (#81) moves the divider programmatically, so
        // AppKit never raises `inLiveResize`. The settle signal coalesces the
        // per-frame reflow that would otherwise flash the surface blank.
        #expect(
            SurfaceResizeUpdatePolicy.decision(
                lastApplied: current, next: next,
                isInLiveResize: false, isSettlingDividerAnimation: true)
                == .deferUntilSettled
        )
    }

    @Test("same-scale size changes apply immediately when neither resizing nor settling")
    func sameScaleSizeChangesApplyImmediatelyWhenIdle() {
        let current = surfaceState(width: 800, height: 600)
        let next = surfaceState(width: 900, height: 640)

        // The post-creation settle correction and plain programmatic layout land
        // here. Applying immediately is what keeps the PTY winsize current for the
        // shell + fastfetch on cold launch.
        #expect(
            SurfaceResizeUpdatePolicy.decision(
                lastApplied: current, next: next,
                isInLiveResize: false, isSettlingDividerAnimation: false)
                == .applyImmediately
        )
    }

    @Test("backing scale changes apply immediately, even mid-resize or settle")
    func scaleChangesApplyImmediately() {
        let current = surfaceState(width: 800, height: 600, scale: 2)
        let next = surfaceState(width: 800, height: 600, scale: 1)

        for settling in [false, true] {
            #expect(
                SurfaceResizeUpdatePolicy.decision(
                    lastApplied: current, next: next,
                    isInLiveResize: true, isSettlingDividerAnimation: settling)
                    == .applyImmediately
            )
        }
    }

    @Test("visibility changes apply immediately, even mid-resize or settle")
    func visibilityChangesApplyImmediately() {
        let current = surfaceState(width: 800, height: 600, isVisible: true)
        let next = surfaceState(width: 800, height: 600, isVisible: false)

        #expect(
            SurfaceResizeUpdatePolicy.decision(
                lastApplied: current, next: next,
                isInLiveResize: false, isSettlingDividerAnimation: true)
                == .applyImmediately
        )
    }

    private func surfaceState(
        width: CGFloat,
        height: CGFloat,
        scale: CGFloat = 2,
        isVisible: Bool = true
    ) -> SurfaceBackingState {
        SurfaceBackingState(
            geometry: SurfaceBackingGeometry(
                pointSize: CGSize(width: width, height: height),
                backingScale: scale
            ),
            isVisible: isVisible
        )
    }
}
