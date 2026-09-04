import Foundation

struct ScrollbackDumpPolicy {
    // Includes decompressed terminal pages, not just the output string.
    static let maximumNativePageBytes = 16 * 1_024 * 1_024

    struct Limits: Equatable {
        let maximumEstimatedBytes: UInt64
        let maximumRows: UInt64
        let estimatedBytesPerCell: UInt64
        let maximumNativeTextBytes: UInt64

        static let `default` = Limits(
            maximumEstimatedBytes: 4 * 1_024 * 1_024,
            maximumRows: 8_192,
            estimatedBytesPerCell: 16,
            maximumNativeTextBytes: 4 * 1_024 * 1_024
        )
    }

    struct Input: Equatable {
        let totalRows: UInt64?
        let currentColumns: UInt64
        let widestObservedColumns: UInt64
        let didRowCountChange: Bool
    }

    enum Decision: Equatable {
        case allow
        case block(BlockReason)
    }

    enum BlockReason: Equatable {
        case unknownSize
        case tooLarge
        case rowCountChanged
        case nativeResultTooLarge
    }

    static func decision(
        for input: Input,
        limits: Limits = .default
    ) -> Decision {
        guard let totalRows = input.totalRows else {
            return .block(.unknownSize)
        }
        guard input.currentColumns > 0, input.widestObservedColumns > 0 else {
            return .block(.unknownSize)
        }
        guard !input.didRowCountChange else {
            return .block(.rowCountChanged)
        }
        guard totalRows <= limits.maximumRows else {
            return .block(.tooLarge)
        }

        let columns = max(input.currentColumns, input.widestObservedColumns)
        let (cellCount, cellCountOverflowed) = totalRows.multipliedReportingOverflow(by: columns)
        guard !cellCountOverflowed else {
            return .block(.tooLarge)
        }
        let (estimatedBytes, estimatedBytesOverflowed) = cellCount.multipliedReportingOverflow(
            by: limits.estimatedBytesPerCell
        )
        guard !estimatedBytesOverflowed,
            estimatedBytes <= limits.maximumEstimatedBytes
        else {
            return .block(.tooLarge)
        }

        return .allow
    }

    static func acceptsNativeText(
        byteCount: UInt64,
        limits: Limits = .default
    ) -> Bool {
        byteCount <= limits.maximumNativeTextBytes
    }
}
