import AwesoMuxBridgeProtocol
import Foundation
import Testing
@testable import AwesoMuxBridgeHelperSupport

@Suite("BoundedUTF8FileReader")
struct BoundedUTF8FileReaderTests {
    @Test("reads a fixture at and below the byte cap")
    func readsWithinCap() throws {
        let directory = FileManager.default.temporaryDirectory
        let underURL = directory.appendingPathComponent("emit-under-\(UUID().uuidString).txt")
        let exactURL = directory.appendingPathComponent("emit-exact-\(UUID().uuidString).txt")
        let cap = 32
        try String(repeating: "a", count: cap - 1).write(to: underURL, atomically: true, encoding: .utf8)
        try String(repeating: "b", count: cap).write(to: exactURL, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: underURL)
            try? FileManager.default.removeItem(at: exactURL)
        }

        #expect(try BoundedUTF8FileReader.read(path: underURL.path, maximumBytes: cap) == String(repeating: "a", count: cap - 1))
        #expect(try BoundedUTF8FileReader.read(path: exactURL.path, maximumBytes: cap) == String(repeating: "b", count: cap))
    }

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

    @Test("rejects invalid UTF-8")
    func rejectsInvalidUTF8() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("emit-invalid-\(UUID().uuidString).bin")
        try Data([0xFF, 0xFE, 0xFD]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: BoundedUTF8FileReader.ReadError.invalidUTF8) {
            try BoundedUTF8FileReader.read(path: url.path)
        }
    }

    @Test("emit stays fail-silent when the fixture exceeds the cap")
    func emitOversizedFixtureIsSilentUnavailable() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("emit-silent-\(UUID().uuidString).txt")
        let oversized = String(
            repeating: "x",
            count: BoundedUTF8FileReader.emitFixtureMaximumBytes + 1
        )
        try oversized.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        var connected = false
        let status = BridgeHelperCommand.run(
            arguments: ["--emit", url.path],
            environment: [
                "AWESOMUX_BRIDGE_STATE": "/state",
                "AWESOMUX_BRIDGE_SESSION": "session",
            ],
            readState: { _ in
                BridgeStateFile(
                    proto: "awesomux-bridge-v1",
                    gen: 1,
                    socket: "/socket",
                    token: "secret"
                )
            },
            connect: { _, _ in
                connected = true
                throw HelperConnection.ConnectionError.connectFailed
            },
            output: { _ in Issue.record("unexpected stdout write") },
            errorOutput: { _ in Issue.record("unexpected stderr write") }
        )
        #expect(status == 0)
        #expect(!connected)
    }
}
