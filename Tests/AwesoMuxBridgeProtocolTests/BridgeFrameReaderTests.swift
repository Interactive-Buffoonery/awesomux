import Foundation
import Testing
@testable import AwesoMuxBridgeProtocol

@Suite
struct BridgeFrameReaderTests {

    private static let token = "tok"
    private static let session = "sess"
    private static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private static func envelopeLine(
        id: String = "id", token: String = token, session: String = session, title: String = "hi"
    ) throws -> String {
        try BridgeEnvelope(
            token: token, session: session, id: id, ts: 1_700_000_000,
            message: .paneRename(title: title)
        ).encodedLine()
    }

    private static func consume(
        _ data: Data, pendingTail: BridgeFrameReader.PendingTail = .empty, now: Date = epoch
    ) -> (frames: [BridgeFrameReader.Frame], tail: BridgeFrameReader.PendingTail, action: BridgeFrameReader.Action) {
        BridgeFrameReader.consume(data, pendingTail: pendingTail, now: now, expectedToken: token, expectedSession: session)
    }

    // MARK: - Split-line reassembly across two consumes

    @Test
    func lineSplitAcrossTwoConsumesReassembles() throws {
        let line = try Self.envelopeLine()
        let full = Data((line + "\n").utf8)
        let splitIndex = full.count / 2

        let firstHalf = Data(full.prefix(splitIndex))
        let first = Self.consume(firstHalf)
        #expect(first.frames.isEmpty)
        #expect(first.tail.bytes == firstHalf)
        #expect(first.tail.startedAt == Self.epoch)
        #expect(first.action == .none)

        let second = Self.consume(Data(full.suffix(from: splitIndex)), pendingTail: first.tail)
        #expect(second.frames.count == 1)
        #expect(second.tail == .empty)
        #expect(second.action == .none)
    }

    @Test
    func lineSplitMidMultiByteCharacterReassembles() throws {
        // The split lands INSIDE the rocket emoji's 4-byte UTF-8 sequence —
        // reassembly must happen on raw bytes, never via a String round-trip
        // that would mangle the torn scalar.
        let line = try Self.envelopeLine(title: "🚀 pad")
        let full = Data((line + "\n").utf8)
        guard let emojiRange = full.firstRange(of: Data("🚀".utf8)) else {
            Issue.record("emoji bytes not found in encoded line")
            return
        }
        let splitIndex = full.index(emojiRange.lowerBound, offsetBy: 2)

        let first = Self.consume(Data(full[..<splitIndex]))
        #expect(first.frames.isEmpty)

        let second = Self.consume(Data(full[splitIndex...]), pendingTail: first.tail)
        #expect(second.frames.count == 1)
        if case .envelope(let envelope) = second.frames.first {
            #expect(envelope.message == .paneRename(title: "🚀 pad"))
        } else {
            Issue.record("expected .envelope")
        }
    }

    // MARK: - Multi-line drain order

    @Test
    func multipleCompleteLinesDrainInOrder() throws {
        let first = try Self.envelopeLine(id: "first")
        let second = try Self.envelopeLine(id: "second")
        let third = try Self.envelopeLine(id: "third")
        let data = Data(([first, second, third].joined(separator: "\n") + "\n").utf8)

        let result = Self.consume(data)

        #expect(result.frames.count == 3)
        let ids: [String] = result.frames.compactMap {
            if case .envelope(let envelope) = $0 { return envelope.id }
            return nil
        }
        #expect(ids == ["first", "second", "third"])
        #expect(result.action == .none)
    }

    @Test
    func validLineSurvivesDroppedSiblingInSameBuffer() throws {
        // An oversized-but-complete garbage line followed by a valid frame:
        // only the bad line drops; the sibling must still decode.
        var data = Data(repeating: 0x61, count: BridgeFrameReader.maximumLineByteCount)
        data.append(0x0A)
        data.append(Data((try Self.envelopeLine() + "\n").utf8))

        let result = Self.consume(data)

        #expect(result.frames.count == 1)
        #expect(result.action == .none)
    }

    // MARK: - Exact 65,536-byte line boundary

    @Test(arguments: [BridgeFrameReader.maximumLineByteCount - 1, BridgeFrameReader.maximumLineByteCount])
    func completeGarbageLineAtOrOverCapDropsWithoutClosing(contentByteCount: Int) {
        var data = Data(repeating: 0x61, count: contentByteCount)
        data.append(0x0A)

        let result = Self.consume(data)

        #expect(result.frames.isEmpty)
        #expect(result.action == .none)
        #expect(result.tail == .empty)
    }

    @Test
    func unterminatedBufferJustUnderCapStaysOpen() {
        let data = Data(repeating: 0x61, count: BridgeFrameReader.maximumLineByteCount - 1)

        let result = Self.consume(data)

        #expect(result.action == .none)
        #expect(result.tail.bytes == data)
    }

    @Test
    func unterminatedBufferAtCapCloses() {
        let data = Data(repeating: 0x61, count: BridgeFrameReader.maximumLineByteCount)

        let result = Self.consume(data)

        #expect(result.frames.isEmpty)
        #expect(result.action == .close(reason: .unterminatedLineTooLarge))
        #expect(result.tail == .empty)
    }

    @Test
    func unterminatedTailAccumulatedAcrossCallsClosesOnceItCrossesCap() {
        let almostCap = Data(repeating: 0x61, count: BridgeFrameReader.maximumLineByteCount - 1)
        let underCap = Self.consume(almostCap)
        #expect(underCap.action == .none)

        let overCap = Self.consume(Data([0x61]), pendingTail: underCap.tail)
        #expect(overCap.action == .close(reason: .unterminatedLineTooLarge))
    }

    @Test
    func completedLinesAreDeliveredEvenWhenTrailingRemainderCloses() throws {
        // One buffer: a valid complete line, then an oversized unterminated
        // remainder. The completed frame arrived intact and must be
        // delivered alongside the close — a refactor that blanks `frames`
        // on close would silently eat delivered data.
        var data = Data((try Self.envelopeLine() + "\n").utf8)
        data.append(Data(repeating: 0x61, count: BridgeFrameReader.maximumLineByteCount))

        let result = Self.consume(data)

        #expect(result.frames.count == 1)
        #expect(result.action == .close(reason: .unterminatedLineTooLarge))
        #expect(result.tail == .empty)
    }

    // MARK: - 10 s partial-frame deadline

    @Test(arguments: [9.9, 10.0])
    func partialLineWithinDeadlineStaysOpen(elapsed: TimeInterval) {
        let held = Self.consume(Data("{\"partial".utf8))
        #expect(held.action == .none)

        let result = Self.consume(Data(), pendingTail: held.tail, now: Self.epoch.addingTimeInterval(elapsed))

        #expect(result.action == .none)
        #expect(result.tail == held.tail)
    }

    @Test
    func partialLineOver10SecondsCloses() {
        let held = Self.consume(Data("{\"partial".utf8))
        #expect(held.action == .none)

        let result = Self.consume(Data(), pendingTail: held.tail, now: Self.epoch.addingTimeInterval(10.1))

        #expect(result.frames.isEmpty)
        #expect(result.action == .close(reason: .partialLineDeadline))
        #expect(result.tail == .empty)
    }

    @Test
    func newlineArrivingWithExpiredTailStillDeliversTheFrame() throws {
        // The deadline defends against a held-open buffer; if THIS call's
        // bytes complete the line, there is no hostage — the frame (e.g. a
        // slow permission decision) is delivered instead of being discarded
        // by a spurious close.
        let line = try Self.envelopeLine()
        let full = Data((line + "\n").utf8)
        let splitIndex = full.count / 2

        let held = Self.consume(Data(full.prefix(splitIndex)))
        let result = Self.consume(
            Data(full.suffix(from: splitIndex)), pendingTail: held.tail, now: Self.epoch.addingTimeInterval(11)
        )

        #expect(result.frames.count == 1)
        #expect(result.action == .none)
        #expect(result.tail == .empty)
    }

    // MARK: - Token / session mismatch, unknown type — drop, stay open

    @Test(arguments: [("wrong-token", "sess"), ("tok", "some-other-pane")])
    func mismatchedIdentityDropsLineButKeepsConnectionOpen(token: String, session: String) throws {
        let line = try Self.envelopeLine(token: token, session: session)
        let result = Self.consume(Data((line + "\n").utf8))

        #expect(result.frames.isEmpty)
        #expect(result.action == .none)
    }

    @Test(arguments: [
        #"{"v":1,"type":"unheard-of","token":"tok","session":"sess","id":"i","ts":1700000000}"#,
        #"{"v":1,"type":"pane-rename""#,
    ])
    func invalidFrameDropsWithoutClosing(line: String) {
        let result = Self.consume(Data((line + "\n").utf8))
        #expect(result.frames.isEmpty)
        #expect(result.action == .none)
    }

    // MARK: - Empty-data consume is a no-op

    // MARK: - Handshake frames surface distinctly

    // MARK: - Constant-time token compare

}
