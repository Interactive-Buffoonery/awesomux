import Foundation
import Testing
@testable import awesoMux

// MARK: - ProcessCodexAppServerTransport — ingest/receive seam tests
//
// The pure `consume()` core is covered in
// `ProcessCodexAppServerTransportConsumeTests`; these tests drive the
// imperative shell around it — `ingest`, `takeBufferedLine`, and the delivery
// ordering inside `receive()` — where framing state meets the caller.

@Suite("ProcessCodexAppServerTransport — ingest/receive seam")
struct ProcessCodexAppServerTransportSeamTests {

    // MARK: - Helpers

    private static func makeTransport() throws -> ProcessCodexAppServerTransport {
        // /bin/cat is guaranteed present and, run argument-less, simply idles
        // on stdin — its only job is letting init succeed without depending on
        // a real `codex` install. The seam calls below never touch the child's
        // stdio.
        try ProcessCodexAppServerTransport(
            executable: "/bin/cat",
            codexHome: "/tmp/awesomux-seam-tests",
            arguments: []
        )
    }

    private static func jsonLine(id: String) -> String {
        #"{"jsonrpc":"2.0","id":"\#(id)","result":{"ok":true}}"#
    }

    private static func framed(_ line: String) -> Data {
        Data((line + "\n").utf8)
    }

    // MARK: - Violation vs queued frames

    @Test
    func completeLineFromViolatingChunkDeliversBeforeTheTransportThrows() async throws {
        let transport = try Self.makeTransport()
        defer { transport.close() }

        // One read carrying a legal response followed by an unterminated run
        // crossing the cap: the exact trigger that used to drop the line.
        var chunk = Self.framed(Self.jsonLine(id: "good"))
        chunk.append(Data(repeating: 0x61, count: ProcessCodexAppServerTransport.maximumLineByteCount + 1))

        transport.ingest(chunk)

        // Assert the queue synchronously first. Against the pre-fix code this
        // line was discarded, and going straight to `receive()` would block
        // forever on the idle child — a suite timeout reads as infrastructure
        // trouble, not as this regression.
        #expect(transport.takeBufferedLine() == Data(Self.jsonLine(id: "good").utf8))
        #expect(transport.takeBufferedLine() == nil)

        // Only once the queue has drained does the violation stop the stream —
        // `receive()` checks the buffer before the pending violation.
        await #expect(
            throws: CodexAppServerError.malformedResponse(
                "codex app-server stream framing violated: unterminatedLineTooLarge"
            )
        ) {
            _ = try await transport.receive()
        }
    }

    // MARK: - Burst draining

    @Test
    func bufferedLinesDrainInOrderWithBoundedWork() throws {
        let transport = try Self.makeTransport()
        defer { transport.close() }

        let count = 200_000
        var chunk = Data()
        chunk.reserveCapacity(count * 64)
        for index in 0..<count {
            chunk.append(Self.framed(Self.jsonLine(id: "m-\(index)")))
        }
        transport.ingest(chunk)

        let start = ContinuousClock.now
        var drainedCount = 0
        var firstLine: String?
        var midLine: String?
        var lastLine: String?
        while let line = transport.takeBufferedLine() {
            let text = String(decoding: line, as: UTF8.self)
            switch drainedCount {
            case 0: firstLine = text
            case count / 2: midLine = text
            default: break
            }
            lastLine = text
            drainedCount += 1
        }
        let elapsed = ContinuousClock.now - start

        #expect(drainedCount == count)
        #expect(firstLine == Self.jsonLine(id: "m-0"))
        #expect(midLine == Self.jsonLine(id: "m-\(count / 2)"))
        #expect(lastLine == Self.jsonLine(id: "m-\(count - 1)"))
        // Cursor-based draining is linear in the burst size. The front-removal
        // version it replaced was quadratic — seconds at this size — and must
        // not come back quietly.
        #expect(elapsed < .seconds(2))
    }

    // MARK: - Tail invariant across a violation

    /// A violation is terminal. `FramingViolation`'s own contract says byte
    /// offsets past the breach are meaningless, so a later chunk must not be
    /// reframed into a deliverable line, and must not replace the pending
    /// violation with its own. Without the guard in `ingest()` the bytes below
    /// reassemble into `{"partial":1}` and are handed to the caller AHEAD of
    /// the violation — a frame built entirely from post-breach bytes.
    @Test
    func ingestAfterAViolationIsDroppedAndCannotDisplaceIt() throws {
        let transport = try Self.makeTransport()
        defer { transport.close() }

        var violatingChunk = Self.framed(Self.jsonLine(id: "good"))
        violatingChunk.append(Data(repeating: 0x61, count: ProcessCodexAppServerTransport.maximumLineByteCount + 1))
        transport.ingest(violatingChunk)

        // The pre-violation frame survives and drains normally…
        #expect(transport.takeBufferedLine() == Data(Self.jsonLine(id: "good").utf8))
        #expect(transport.takeBufferedLine() == nil)

        // …and nothing after the breach is ever framed.
        transport.ingest(Data(#"{"partial""#.utf8))
        transport.ingest(Data((#":1}"# + "\n").utf8))
        #expect(transport.takeBufferedLine() == nil)

        // The original violation is still the one that surfaces, not a later
        // one raised by the dropped chunks.
        #expect(transport.takePendingViolation() == .unterminatedLineTooLarge)
    }
}
