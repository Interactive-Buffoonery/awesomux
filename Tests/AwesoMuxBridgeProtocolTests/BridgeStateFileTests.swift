import Foundation
import Testing
@testable import AwesoMuxBridgeProtocol

@Suite
struct BridgeStateFileTests {

    @Test
    func roundTrips() throws {
        let state = BridgeStateFile(proto: "awesomux-bridge-v1", gen: 3, socket: "/tmp/awesomux-bridge-9f3a1c.sock", token: "4f3c-a19b")

        let data = try JSONEncoder().encode(state)
        #expect(BridgeStateFile.parse(data: data) == state)
    }

    @Test
    func exactlyAtByteCapDecodes() throws {
        // Pad the token so the encoded JSON lands exactly at the 4 KiB cap.
        let base = BridgeStateFile(proto: "awesomux-bridge-v1", gen: 1, socket: "/tmp/s.sock", token: "")
        let baseSize = try JSONEncoder().encode(base).count
        let padding = String(repeating: "a", count: BridgeStateFile.maximumByteCount - baseSize)
        let state = BridgeStateFile(proto: "awesomux-bridge-v1", gen: 1, socket: "/tmp/s.sock", token: padding)

        let data = try JSONEncoder().encode(state)
        #expect(data.count == BridgeStateFile.maximumByteCount)
        #expect(BridgeStateFile.parse(data: data) == state)
    }

    @Test
    func overByteCapIsRejected() throws {
        let oversizedToken = String(repeating: "a", count: BridgeStateFile.maximumByteCount + 1)
        let state = BridgeStateFile(proto: "awesomux-bridge-v1", gen: 1, socket: "/tmp/s.sock", token: oversizedToken)

        let data = try JSONEncoder().encode(state)
        #expect(data.count > BridgeStateFile.maximumByteCount)
        #expect(BridgeStateFile.parse(data: data) == nil)
    }

    @Test
    func nonAbsoluteSocketIsRejected() throws {
        let state = BridgeStateFile(proto: "awesomux-bridge-v1", gen: 1, socket: "relative/path.sock", token: "tok")

        let data = try JSONEncoder().encode(state)
        #expect(BridgeStateFile.parse(data: data) == nil)
    }

    @Test
    func emptySocketIsRejected() throws {
        let state = BridgeStateFile(proto: "awesomux-bridge-v1", gen: 1, socket: "", token: "tok")

        let data = try JSONEncoder().encode(state)
        #expect(BridgeStateFile.parse(data: data) == nil)
    }

    @Test
    func socketWithEmbeddedNULIsRejected() throws {
        // An embedded NUL makes the C string a later connect(2) sees a
        // PREFIX of the validated value — the classic truncation spoof.
        let state = BridgeStateFile(proto: "awesomux-bridge-v1", gen: 1, socket: "/tmp/a.sock\u{0000}/suffix", token: "tok")

        let data = try JSONEncoder().encode(state)
        #expect(BridgeStateFile.parse(data: data) == nil)
    }

    @Test
    func socketWithBidiOverrideIsRejected() throws {
        let state = BridgeStateFile(proto: "awesomux-bridge-v1", gen: 1, socket: "/tmp/\u{202E}kcos.a", token: "tok")

        let data = try JSONEncoder().encode(state)
        #expect(BridgeStateFile.parse(data: data) == nil)
    }

    @Test
    func malformedJSONIsRejected() {
        #expect(BridgeStateFile.parse(data: Data(#"{"proto":"#.utf8)) == nil)
    }

    @Test
    func missingRequiredFieldIsRejected() {
        let json = #"{"proto":"awesomux-bridge-v1","gen":1,"socket":"/tmp/s.sock"}"# // no token
        #expect(BridgeStateFile.parse(data: Data(json.utf8)) == nil)
    }
}
