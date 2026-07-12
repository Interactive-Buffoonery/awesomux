import Foundation

struct SurfaceScrollbar: Equatable {
    let total: UInt64
    let offset: UInt64
    let length: UInt64

    var visibleLength: UInt64 {
        min(length, total)
    }

    var maximumVisibleStartRow: Int {
        Int(min(UInt64(Int.max), maximumVisibleStartRowRaw))
    }

    var visibleStartRow: Int {
        Int(min(UInt64(Int.max), min(offset, maximumVisibleStartRowRaw)))
    }

    var rowsBelowVisibleStart: UInt64 {
        let clampedOffset = min(offset, maximumVisibleStartRowRaw)
        return maximumVisibleStartRowRaw - clampedOffset
    }

    private var maximumVisibleStartRowRaw: UInt64 {
        total > visibleLength ? total - visibleLength : 0
    }
}
