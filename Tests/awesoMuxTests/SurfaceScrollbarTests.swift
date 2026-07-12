import Testing
@testable import awesoMux

@Suite("SurfaceScrollbar")
struct SurfaceScrollbarTests {
    @Test("rows below visible start saturates when offset exceeds scrollback")
    func rowsBelowVisibleStartSaturatesWhenOffsetExceedsScrollback() {
        let scrollbar = SurfaceScrollbar(total: 10, offset: 12, length: 5)

        #expect(scrollbar.maximumVisibleStartRow == 5)
        #expect(scrollbar.visibleStartRow == 5)
        #expect(scrollbar.rowsBelowVisibleStart == 0)
    }

    @Test("rows below visible start handles viewports larger than total rows")
    func rowsBelowVisibleStartHandlesViewportLargerThanTotalRows() {
        let scrollbar = SurfaceScrollbar(total: 3, offset: 10, length: 8)

        #expect(scrollbar.maximumVisibleStartRow == 0)
        #expect(scrollbar.visibleStartRow == 0)
        #expect(scrollbar.rowsBelowVisibleStart == 0)
        #expect(scrollbar.visibleLength == 3)
    }
}
