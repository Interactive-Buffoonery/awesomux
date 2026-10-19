import AwesoMuxBridgeProtocol
import Foundation
import Testing
@testable import AwesoMuxBridgeHelperSupport

@Suite("BoundedUTF8FileReader")
struct BoundedUTF8FileReaderTests {

    @Test("rejects a fixture one byte over the cap")
    func rejectsOverCap() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("emit-over-\(UUID().uuidString).txt")
        let cap = 32
        try String(repeating: "c", count: cap + 1).write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: BoundedUTF8FileReader.ReadError.tooLarge) {
            try BoundedUTF8FileReader.read(path: url.path, maximumBytes: cap)
        }
    }

}
