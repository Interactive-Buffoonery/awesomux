import Foundation
import Testing
@testable import AwesoMuxCore

@Suite
struct BridgeHandshakeTests {

    @Test
    func helloRoundTrips() throws {
        let handshake = BridgeHandshake.hello(
            proto: "awesomux-bridge-v1", token: "4f3c…a19b", session: "7b1e-uuid", ts: 1_790_429_673,
            helper: "awesomux-remote-helper/1.0.0"
        )

        let decoded = BridgeHandshake.parse(line: try handshake.encodedLine())
        #expect(decoded == handshake)
    }

    @Test
    func helloAckRoundTrips() throws {
        let handshake = BridgeHandshake.helloAck(session: "7b1e-uuid", proto: "awesomux-bridge-v1", ts: 1_790_429_675)

        let decoded = BridgeHandshake.parse(line: try handshake.encodedLine())
        #expect(decoded == handshake)
    }

    @Test
    func helloNackRoundTrips() throws {
        let handshake = BridgeHandshake.helloNack(supported: ["awesomux-bridge-v1"])

        let decoded = BridgeHandshake.parse(line: try handshake.encodedLine())
        #expect(decoded == handshake)
    }

    /// The whole reason `hello-nack` exists is to answer a `hello` whose
    /// validation never got past `proto` — it must decode with no
    /// `token`/`session` present at all, unlike every envelope frame.
    @Test
    func helloNackDecodesWithoutTokenOrSession() {
        let line = #"{"type":"hello-nack","supported":["awesomux-bridge-v1"]}"#
        let decoded = BridgeHandshake.parse(line: line)

        #expect(decoded == .helloNack(supported: ["awesomux-bridge-v1"]))
    }

    @Test
    func handshakeFramesCarryNoVersionField() {
        // No "v" key anywhere — handshake is exempt from the envelope's
        // required-field set, per the spec's Handshake section.
        let line = #"{"type":"hello-ack","session":"s","proto":"awesomux-bridge-v1","ts":1700000000}"#
        #expect(BridgeHandshake.parse(line: line) != nil)
    }

    @Test
    func unknownHandshakeTypeIsDropped() {
        let line = #"{"type":"hello-maybe","session":"s"}"#
        #expect(BridgeHandshake.parse(line: line) == nil)
    }

    @Test
    func helloMissingRequiredFieldIsDropped() {
        // Missing "helper".
        let line = #"{"type":"hello","proto":"awesomux-bridge-v1","token":"tok","session":"s","ts":1700000000}"#
        #expect(BridgeHandshake.parse(line: line) == nil)
    }

    @Test
    func malformedJSONIsDropped() {
        #expect(BridgeHandshake.parse(line: #"{"type":"hello""#) == nil)
    }
}
