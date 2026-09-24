import Foundation
import Testing
@testable import AwesoMuxBridgeProtocol

@Suite
struct BridgeHandshakeTests {

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
