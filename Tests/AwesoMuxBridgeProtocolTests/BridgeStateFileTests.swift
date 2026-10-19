import Foundation
import Testing
@testable import AwesoMuxBridgeProtocol

@Suite
struct BridgeStateFileTests {

    @Test
    func overByteCapIsRejected() throws {
        let oversizedToken = String(repeating: "a", count: BridgeStateFile.maximumByteCount + 1)
        let state = BridgeStateFile(proto: "awesomux-bridge-v1", gen: 1, socket: "/tmp/s.sock", token: oversizedToken)

        let data = try JSONEncoder().encode(state)
        #expect(data.count > BridgeStateFile.maximumByteCount)
        #expect(BridgeStateFile.parse(data: data) == nil)
    }

    @Test(arguments: ["relative/path.sock", "", "/tmp/a.sock\u{0000}/suffix", "/tmp/\u{202E}kcos.a"])
    func unsafeSocketIsRejected(socket: String) throws {
        let state = BridgeStateFile(proto: "awesomux-bridge-v1", gen: 1, socket: socket, token: "tok")
        #expect(BridgeStateFile.parse(data: try JSONEncoder().encode(state)) == nil)
    }

}
