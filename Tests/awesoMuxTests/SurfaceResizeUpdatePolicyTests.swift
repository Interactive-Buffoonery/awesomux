import AwesoMuxCore
import CoreGraphics
import Testing
@testable import awesoMux

@Suite("Surface resize update policy")
struct SurfaceResizeUpdatePolicyTests {
    @Test("first geometry applies immediately, even mid-live-resize")
    func firstGeometryAppliesImmediately() {
        let state = surfaceState(width: 800, height: 600)

        // A freshly created surface (nil lastApplied) must never be deferred —
        // this is the cold-launch guarantee that protects fastfetch sizing
        // (INT-289). True regardless of live-resize state.
        #expect(
            SurfaceResizeUpdatePolicy.decision(
                lastApplied: nil, next: state, isInLiveResize: false)
                == .applyImmediately
        )
        #expect(
            SurfaceResizeUpdatePolicy.decision(
                lastApplied: nil, next: state, isInLiveResize: true)
                == .applyImmediately
        )
    }

    @Test("identical geometry is skipped")
    func identicalGeometrySkips() {
        let state = surfaceState(width: 800, height: 600)

        #expect(
            SurfaceResizeUpdatePolicy.decision(
                lastApplied: state, next: state, isInLiveResize: true)
                == .skip
        )
    }

    @Test("same-scale size changes defer only during a live resize")
    func sameScaleSizeChangesDeferDuringLiveResize() {
        let current = surfaceState(width: 800, height: 600)
        let next = surfaceState(width: 900, height: 640)

        #expect(
            SurfaceResizeUpdatePolicy.decision(
                lastApplied: current, next: next, isInLiveResize: true)
                == .deferUntilSettled
        )
    }

    @Test("same-scale size changes apply immediately when not live-resizing")
    func sameScaleSizeChangesApplyImmediatelyWhenNotLiveResizing() {
        let current = surfaceState(width: 800, height: 600)
        let next = surfaceState(width: 900, height: 640)

        // The post-creation settle correction and programmatic layout land here
        // (a native divider drag is a real `inLiveResize`, so it coalesces instead).
        // Applying immediately is what keeps the PTY winsize current for the
        // shell + fastfetch on cold launch.
        #expect(
            SurfaceResizeUpdatePolicy.decision(
                lastApplied: current, next: next, isInLiveResize: false)
                == .applyImmediately
        )
    }

    @Test("backing scale changes apply immediately, even mid-live-resize")
    func scaleChangesApplyImmediately() {
        let current = surfaceState(width: 800, height: 600, scale: 2)
        let next = surfaceState(width: 800, height: 600, scale: 1)

        #expect(
            SurfaceResizeUpdatePolicy.decision(
                lastApplied: current, next: next, isInLiveResize: true)
                == .applyImmediately
        )
    }

    @Test("visibility changes apply immediately, even mid-live-resize")
    func visibilityChangesApplyImmediately() {
        let current = surfaceState(width: 800, height: 600, isVisible: true)
        let next = surfaceState(width: 800, height: 600, isVisible: false)

        #expect(
            SurfaceResizeUpdatePolicy.decision(
                lastApplied: current, next: next, isInLiveResize: true)
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
