import Foundation
import Testing
@testable import awesoMux

// MARK: - ProcessCodexAppServerTransport — pure consume() core tests
//
// These tests exercise the pure framing state machine
// `ProcessCodexAppServerTransport.consume(_:pendingTail:tailStartedAt:now:)`,
// which needs no spawned `codex app-server` process — the same split between
// pure core and I/O shell that `AmxStatusFileWatcher` and `BridgeFrameReader`
// use for their guard tests.

@Suite("ProcessCodexAppServerTransport — consume() core")
struct ProcessCodexAppServerTransportConsumeTests {

    // MARK: - Helpers

    private static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private static func jsonLine(id: String) -> String {
        #"{"jsonrpc":"2.0","id":"\#(id)","result":{"ok":true}}"#
    }

    private static func framed(_ line: String) -> Data {
        Data((line + "\n").utf8)
    }

    private static func consume(
        _ data: Data,
        pendingTail: Data = Data(),
        tailStartedAt: Date? = nil,
        now: Date = epoch
    ) -> (
        lines: [Data],
        tail: Data,
        tailStartedAt: Date?,
        violation: ProcessCodexAppServerTransport.FramingViolation?
    ) {
        ProcessCodexAppServerTransport.consume(
            data,
            pendingTail: pendingTail,
            tailStartedAt: tailStartedAt,
            now: now
        )
    }

    // MARK: - Multi-line extraction

    @Test
    func multipleCompleteLinesDrainInOrder() {
        let data = Data(
            ([Self.jsonLine(id: "first"), Self.jsonLine(id: "second"), Self.jsonLine(id: "third")]
                .map { Self.framed($0) })
                .reduce(Data(), +)
        )

        let result = Self.consume(data)

        #expect(result.violation == nil)
        #expect(result.tail.isEmpty)
        #expect(result.tailStartedAt == nil)
        let ids = result.lines.compactMap { String(data: $0, encoding: .utf8) }
        #expect(ids == [Self.jsonLine(id: "first"), Self.jsonLine(id: "second"), Self.jsonLine(id: "third")])
    }

    @Test
    func burstOfManyLinesExtractsAllInOnePass() {
        // The old per-line `removeSubrange` made this burst O(n²) over the
        // buffer; startIndex-based slicing must extract every line intact.
        let count = 5_000
        var data = Data()
        for index in 0..<count {
            data.append(Self.framed(Self.jsonLine(id: "m-\(index)")))
        }

        let result = Self.consume(data)

        #expect(result.violation == nil)
        #expect(result.lines.count == count)
        #expect(result.tail.isEmpty)
        let first = String(data: result.lines[0], encoding: .utf8)
        let last = String(data: result.lines[count - 1], encoding: .utf8)
        #expect(first == Self.jsonLine(id: "m-0"))
        #expect(last == Self.jsonLine(id: "m-\(count - 1)"))
    }

    @Test
    func lineSplitAcrossTwoConsumesReassembles() {
        let full = Self.framed(Self.jsonLine(id: "split"))
        let splitIndex = full.count / 2

        let first = Self.consume(Data(full.prefix(splitIndex)))
        #expect(first.lines.isEmpty)
        #expect(first.violation == nil)
        #expect(first.tail == Data(full.prefix(splitIndex)))

        let second = Self.consume(
            Data(full.suffix(from: splitIndex)),
            pendingTail: first.tail,
            tailStartedAt: first.tailStartedAt
        )
        #expect(second.lines == [Self.jsonLine(id: "split").utf8Data])
        #expect(second.tail.isEmpty)
        #expect(second.violation == nil)
    }

    // MARK: - Partial-line hold (no newline)

    @Test
    func unterminatedUnderCapHoldsAsTail() {
        let partial = Data("{\"jsonrpc\":\"2.0\",\"partial".utf8)

        let result = Self.consume(partial, now: Self.epoch)

        #expect(result.lines.isEmpty)
        #expect(result.violation == nil)
        #expect(result.tail == partial)
        #expect(result.tailStartedAt == Self.epoch)
    }

    @Test
    func unterminatedTailAtExactCapStillHolds() {
        // Exactly the cap is still held — the violation fires on growth past it.
        let data = Data(repeating: 0x61, count: ProcessCodexAppServerTransport.maximumLineByteCount)

        let result = Self.consume(data)

        #expect(result.violation == nil)
        #expect(result.tail == data)
    }

    @Test
    func unterminatedTailCrossingCapViolates() {
        let almostCap = Data(repeating: 0x61, count: ProcessCodexAppServerTransport.maximumLineByteCount)
        let held = Self.consume(almostCap)
        #expect(held.violation == nil)

        let result = Self.consume(
            Data([0x61]),
            pendingTail: held.tail,
            tailStartedAt: held.tailStartedAt
        )

        #expect(result.lines.isEmpty)
        #expect(result.violation == .unterminatedLineTooLarge)
        #expect(result.tail.isEmpty)
        #expect(result.tailStartedAt == nil)
    }

    @Test
    func continuingTailKeepsItsOriginalStartedAt() {
        let held = Self.consume(Data("{\"partial".utf8), now: Self.epoch)

        let result = Self.consume(
            Data([0x62]),
            pendingTail: held.tail,
            tailStartedAt: held.tailStartedAt,
            now: Self.epoch.addingTimeInterval(3)
        )

        #expect(result.violation == nil)
        #expect(result.tailStartedAt == Self.epoch)
    }

    // MARK: - 10 s partial-line deadline

    @Test
    func partialLineAtExactlyDeadlineStaysOpen() {
        // Strictly-greater comparison, matching BridgeFrameReader.
        let held = Self.consume(Data("{\"partial".utf8))

        let result = Self.consume(
            Data(),
            pendingTail: held.tail,
            tailStartedAt: held.tailStartedAt,
            now: Self.epoch.addingTimeInterval(ProcessCodexAppServerTransport.partialLineDeadline)
        )

        #expect(result.violation == nil)
        #expect(result.tail == held.tail)
    }

    @Test
    func partialLinePastDeadlineViolates() {
        let held = Self.consume(Data("{\"partial".utf8))

        let result = Self.consume(
            Data(),
            pendingTail: held.tail,
            tailStartedAt: held.tailStartedAt,
            now: Self.epoch.addingTimeInterval(ProcessCodexAppServerTransport.partialLineDeadline + 0.1)
        )

        #expect(result.lines.isEmpty)
        #expect(result.violation == .partialLineDeadline)
        #expect(result.tail.isEmpty)
    }

    @Test
    func newlineArrivingWithExpiredTailStillDeliversTheFrame() {
        // The deadline defends against a held-open buffer; bytes that complete
        // the line are delivered regardless of the tail's age.
        let full = Self.framed(Self.jsonLine(id: "slow"))
        let splitIndex = full.count / 2

        let held = Self.consume(Data(full.prefix(splitIndex)))
        let result = Self.consume(
            Data(full.suffix(from: splitIndex)),
            pendingTail: held.tail,
            tailStartedAt: held.tailStartedAt,
            now: Self.epoch.addingTimeInterval(60)
        )

        #expect(result.lines == [Self.jsonLine(id: "slow").utf8Data])
        #expect(result.violation == nil)
    }

    // MARK: - Line cap on complete lines

    @Test
    func completeLineOverCapIsDroppedAndSiblingsSurvive() {
        // A complete (newline-terminated) line over the cap is a drop, not a
        // violation — the newline means no bytes are held hostage.
        var data = Data(repeating: 0x61, count: ProcessCodexAppServerTransport.maximumLineByteCount + 1)
        data.append(0x0A)
        data.append(Self.framed(Self.jsonLine(id: "after")))

        let result = Self.consume(data)

        #expect(result.lines == [Self.jsonLine(id: "after").utf8Data])
        #expect(result.violation == nil)
        #expect(result.tail.isEmpty)
    }

    @Test
    func completeLineAtExactCapIsDelivered() {
        var data = Data(repeating: 0x61, count: ProcessCodexAppServerTransport.maximumLineByteCount)
        data.append(0x0A)

        let result = Self.consume(data)

        #expect(result.lines.count == 1)
        #expect(result.lines[0].count == ProcessCodexAppServerTransport.maximumLineByteCount)
        #expect(result.violation == nil)
    }

    @Test
    func completedLinesAreDeliveredEvenWhenTrailingRemainderViolates() {
        var data = Self.framed(Self.jsonLine(id: "good"))
        data.append(Data(repeating: 0x61, count: ProcessCodexAppServerTransport.maximumLineByteCount + 1))

        let result = Self.consume(data)

        #expect(result.lines == [Self.jsonLine(id: "good").utf8Data])
        #expect(result.violation == .unterminatedLineTooLarge)
    }

    // MARK: - Degenerate input

    @Test
    func emptyConsumeIsANoOp() {
        let result = Self.consume(Data())

        #expect(result.lines.isEmpty)
        #expect(result.tail.isEmpty)
        #expect(result.tailStartedAt == nil)
        #expect(result.violation == nil)
    }

    @Test
    func emptyLinesAreDropped() {
        let result = Self.consume(Data("\n\n".utf8))

        #expect(result.lines.isEmpty)
        #expect(result.violation == nil)
        #expect(result.tail.isEmpty)
    }
}

private extension String {
    var utf8Data: Data { Data(self.utf8) }
}
