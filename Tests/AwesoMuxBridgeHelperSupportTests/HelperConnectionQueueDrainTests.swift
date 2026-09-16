import AwesoMuxBridgeProtocol
#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif
import Foundation
import Testing
@testable import AwesoMuxBridgeHelperSupport

/// Seam coverage for `HelperConnection`'s queued-frame drain — mirrors
/// `ProcessCodexAppServerTransportSeamTests.bufferedLinesDrainInOrderWithBoundedWork`.
@Suite
struct HelperConnectionQueueDrainTests {
    @Test
    func queuedFramesDrainInOrderWithBoundedWork() throws {
        let connection = try Self.makeConnection()
        defer { withExtendedLifetime(connection) {} }

        let count = 200_000
        var frames: [BridgeFrameReader.Frame] = []
        frames.reserveCapacity(count)
        for index in 0..<count {
            frames.append(
                .handshake(
                    .helloAck(session: "session", proto: "awesomux-bridge-v1", ts: Double(index))
                )
            )
        }
        connection.enqueueFramesForTesting(frames)

        let start = ContinuousClock.now
        var drainedCount = 0
        var firstFrame: BridgeFrameReader.Frame?
        var midFrame: BridgeFrameReader.Frame?
        var lastFrame: BridgeFrameReader.Frame?
        while let frame = connection.takeQueuedFrame() {
            switch drainedCount {
            case 0: firstFrame = frame
            case count / 2: midFrame = frame
            default: break
            }
            lastFrame = frame
            drainedCount += 1
        }
        let elapsed = ContinuousClock.now - start

        #expect(drainedCount == count)
        #expect(
            firstFrame
                == .handshake(.helloAck(session: "session", proto: "awesomux-bridge-v1", ts: 0))
        )
        #expect(
            midFrame
                == .handshake(
                    .helloAck(session: "session", proto: "awesomux-bridge-v1", ts: Double(count / 2))
                )
        )
        #expect(
            lastFrame
                == .handshake(
                    .helloAck(
                        session: "session", proto: "awesomux-bridge-v1", ts: Double(count - 1)
                    )
                )
        )
        // Cursor-based draining is linear in the burst size. The front-removal
        // version it replaced was quadratic — seconds at this size — and must
        // not come back quietly.
        #expect(elapsed < .seconds(2))
    }

    private static func makeConnection() throws -> HelperConnection {
        var sockets: [Int32] = [0, 0]
        #if canImport(Darwin)
            let pairResult = Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets)
        #elseif canImport(Glibc)
            let pairResult = Glibc.socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &sockets)
        #elseif canImport(Musl)
            let pairResult = Musl.socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets)
        #endif
        guard pairResult == 0 else {
            throw HelperConnection.ConnectionError.connectFailed
        }
        // HelperConnection owns sockets[0] and closes it on deinit.
        close(sockets[1])
        return HelperConnection(fileDescriptor: sockets[0], token: "token", session: "session")
    }
}
