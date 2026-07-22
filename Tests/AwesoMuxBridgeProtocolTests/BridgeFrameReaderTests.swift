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

    // MARK: - Partial-line hold + extraction

    @Test
    func partialLineIsHeldUntilNewlineArrives() throws {
        let line = try Self.envelopeLine()
        let splitIndex = line.utf8.count / 2
        let firstHalf = Data(line.utf8.prefix(splitIndex))

        let result = Self.consume(firstHalf)

        #expect(result.frames.isEmpty)
        #expect(result.tail.bytes == firstHalf)
        #expect(result.tail.startedAt == Self.epoch)
        #expect(result.action == .none)
    }

    @Test
    func completeLineIsExtractedImmediately() throws {
        let line = try Self.envelopeLine()
        let data = Data((line + "\n").utf8)

        let result = Self.consume(data)

        #expect(result.frames.count == 1)
        #expect(result.tail == .empty)
        #expect(result.action == .none)
        if case .envelope(let envelope) = result.frames.first {
            #expect(envelope.message == .paneRename(title: "hi"))
        } else {
            Issue.record("expected .envelope")
        }
    }

    // MARK: - Split-line reassembly across two consumes

    @Test
    func lineSplitAcrossTwoConsumesReassembles() throws {
        let line = try Self.envelopeLine()
        let full = Data((line + "\n").utf8)
        let splitIndex = full.count / 2

        let first = Self.consume(Data(full.prefix(splitIndex)))
        #expect(first.frames.isEmpty)
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

    @Test
    func completeLineAtExactCapPassesThroughWithoutClosing() {
        // 65,535 content bytes + 1 newline byte = exactly the 65,536 cap.
        // Garbage content (not valid JSON) is fine here — this test asserts
        // the size gate lets it through to parsing (drop, not close), not
        // that garbage decodes successfully.
        var data = Data(repeating: 0x61, count: BridgeFrameReader.maximumLineByteCount - 1)
        data.append(0x0A)

        let result = Self.consume(data)

        #expect(result.frames.isEmpty) // garbage, not valid JSON — dropped
        #expect(result.action == .none) // but NOT closed: size was within the cap
        #expect(result.tail == .empty)
    }

    @Test
    func completeLineOverCapIsDroppedNotClosed() {
        // 65,536 content bytes + newline = 65,537 total: over the cap but
        // newline-terminated, so per the spec's failure-mode table it's a
        // silent drop — the close is reserved for the UNTERMINATED case.
        var data = Data(repeating: 0x61, count: BridgeFrameReader.maximumLineByteCount)
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

    @Test
    func partialLineUnder10SecondsStaysOpen() {
        let held = Self.consume(Data("{\"partial".utf8))
        #expect(held.action == .none)

        let result = Self.consume(Data(), pendingTail: held.tail, now: Self.epoch.addingTimeInterval(9.9))

        #expect(result.action == .none)
        #expect(result.tail == held.tail)
    }

    @Test
    func partialLineAtExactly10SecondsStaysOpen() {
        // Spec says "older than 10 s" — strictly greater, so exactly 10.0
        // is still within the deadline.
        let held = Self.consume(Data("{\"partial".utf8))

        let result = Self.consume(Data(), pendingTail: held.tail, now: Self.epoch.addingTimeInterval(10))

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

    @Test
    func pendingTailInitializerNormalizesEmptyBytesWithStaleDate() {
        // The documented invariant (startedAt nil exactly when bytes empty)
        // is enforced by construction: a caller bug pairing empty bytes with
        // a stale date must not fabricate a deadline close.
        let inconsistent = BridgeFrameReader.PendingTail(bytes: Data(), startedAt: .distantPast)
        #expect(inconsistent.startedAt == nil)

        let result = Self.consume(Data(), pendingTail: inconsistent, now: Self.epoch)
        #expect(result.action == .none)
    }

    // MARK: - Token / session mismatch, unknown type — drop, stay open

    @Test
    func tokenMismatchDropsLineButKeepsConnectionOpen() throws {
        let line = try Self.envelopeLine(token: "wrong-token")
        let result = Self.consume(Data((line + "\n").utf8))

        #expect(result.frames.isEmpty)
        #expect(result.action == .none)
    }

    @Test
    func sessionMismatchDropsLineButKeepsConnectionOpen() throws {
        // An authenticated-but-confused (or hostile) helper claiming another
        // pane's session id must not have its frame routed anywhere.
        let line = try Self.envelopeLine(session: "some-other-pane")
        let result = Self.consume(Data((line + "\n").utf8))

        #expect(result.frames.isEmpty)
        #expect(result.action == .none)
    }

    @Test
    func unknownTypeDropsLineButKeepsConnectionOpen() {
        let line = #"{"v":1,"type":"unheard-of","token":"tok","session":"sess","id":"i","ts":1700000000}"#
        let result = Self.consume(Data((line + "\n").utf8))

        #expect(result.frames.isEmpty)
        #expect(result.action == .none)
    }

    @Test
    func malformedJSONLineDropsButKeepsConnectionOpen() {
        let result = Self.consume(Data((#"{"v":1,"type":"pane-rename""# + "\n").utf8))

        #expect(result.frames.isEmpty)
        #expect(result.action == .none)
    }

    // MARK: - Empty-data consume is a no-op

    @Test
    func emptyDataConsumeIsANoOp() {
        let result = Self.consume(Data())

        #expect(result.frames.isEmpty)
        #expect(result.tail == .empty)
        #expect(result.action == .none)
    }

    // MARK: - Handshake frames surface distinctly

    @Test
    func helloLineSurfacesAsHandshakeNotEnvelope() throws {
        let hello = BridgeHandshake.hello(
            proto: "awesomux-bridge-v1", token: "tok", session: "sess", ts: 1_700_000_000,
            helper: "awesomux-remote-helper/1.0.0"
        )
        let result = Self.consume(Data((try hello.encodedLine() + "\n").utf8))

        #expect(result.frames == [.handshake(hello)])
        #expect(result.action == .none)
    }

    // MARK: - Constant-time token compare

    @Test
    func constantTimeEqualsMatchesStringEquality() {
        #expect(BridgeFrameReader.constantTimeEquals("tok", "tok"))
        #expect(!BridgeFrameReader.constantTimeEquals("tok", "toX"))
        #expect(!BridgeFrameReader.constantTimeEquals("tok", "tokk"))
        #expect(!BridgeFrameReader.constantTimeEquals("", "tok"))
        #expect(BridgeFrameReader.constantTimeEquals("", ""))
    }
}
