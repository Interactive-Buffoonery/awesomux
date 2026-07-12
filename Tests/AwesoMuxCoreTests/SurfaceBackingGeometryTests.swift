import CoreGraphics
import Testing
@testable import AwesoMuxCore

@Suite("Surface backing geometry")
struct SurfaceBackingGeometryTests {
    @Test("scales point size by backing factor")
    func scalesByBackingFactor() {
        let geometry = SurfaceBackingGeometry(
            pointSize: CGSize(width: 800, height: 600),
            backingScale: 2
        )
        #expect(geometry.scale == 2)
        #expect(geometry.width == 1600)
        #expect(geometry.height == 1200)
    }

    @Test("floors zero-sized dimensions to 1 backing pixel")
    func floorsZeroToOne() {
        let zero = SurfaceBackingGeometry(
            pointSize: .zero,
            backingScale: 2
        )
        #expect(zero.width == 1)
        #expect(zero.height == 1)

        let zeroHeight = SurfaceBackingGeometry(
            pointSize: CGSize(width: 100, height: 0),
            backingScale: 2
        )
        #expect(zeroHeight.width == 200)
        #expect(zeroHeight.height == 1)
    }

    @Test("truncates sub-pixel point dimensions")
    func truncatesSubpixel() {
        // 847.6 × 2 = 1695.2 → UInt32 truncates to 1695
        let geometry = SurfaceBackingGeometry(
            pointSize: CGSize(width: 847.6, height: 100),
            backingScale: 2
        )
        #expect(geometry.width == 1695)
    }

    @Test("equal point sizes at equal scale compare equal")
    func equalityForIdenticalInputs() {
        let a = SurfaceBackingGeometry(
            pointSize: CGSize(width: 400, height: 300),
            backingScale: 2
        )
        let b = SurfaceBackingGeometry(
            pointSize: CGSize(width: 400, height: 300),
            backingScale: 2
        )
        #expect(a == b)
    }

    @Test("scale change alone breaks equality")
    func scaleChangeBreaksEquality() {
        let onex = SurfaceBackingGeometry(
            pointSize: CGSize(width: 400, height: 300),
            backingScale: 1
        )
        let twox = SurfaceBackingGeometry(
            pointSize: CGSize(width: 200, height: 150),
            backingScale: 2
        )
        // Same backing pixel dimensions (400×300) but different scale —
        // libghostty's content-scale call cares about the scale, so these
        // must NOT compare equal.
        #expect(onex.width == twox.width)
        #expect(onex.height == twox.height)
        #expect(onex != twox)
    }

    @Test("surface backing state includes occlusion")
    func backingStateIncludesOcclusion() {
        let geometry = SurfaceBackingGeometry(
            pointSize: CGSize(width: 400, height: 300),
            backingScale: 2
        )

        #expect(
            SurfaceBackingState(geometry: geometry, isVisible: true)
                == SurfaceBackingState(geometry: geometry, isVisible: true)
        )
        #expect(
            SurfaceBackingState(geometry: geometry, isVisible: true)
                != SurfaceBackingState(geometry: geometry, isVisible: false)
        )
    }
}
