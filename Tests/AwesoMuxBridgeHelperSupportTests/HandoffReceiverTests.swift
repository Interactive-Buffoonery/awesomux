import AwesoMuxTestSupport
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

@Suite("Remote handoff receiver")
struct HandoffReceiverTests {
    @Test("writes exact bytes with private modes and a bounded receipt")
    func receivesExactBytes() throws {
        let home = try TemporaryDirectory(prefix: "handoff-home")
        let payload = Data("# hello\n".utf8)
        let input = try inputDescriptor(payload)
        defer { close(input) }

        let receipt = try HandoffReceiver.receive(
            session: "session-1",
            advisoryName: "notes.md",
            expectedBytes: payload.count,
            inputDescriptor: input,
            homeDirectory: home.url
        )

        #expect(try Data(contentsOf: URL(fileURLWithPath: receipt.path)) == payload)
        #expect(receipt.bytes == payload.count)
        #expect(receipt.path.hasPrefix(home.url.path + "/.awesomux/handoffs/session-1/"))
        #expect(mode(at: home.url.appendingPathComponent(".awesomux")) == 0o700)
        #expect(mode(at: home.url.appendingPathComponent(".awesomux/handoffs")) == 0o700)
        #expect(mode(at: home.url.appendingPathComponent(".awesomux/handoffs/session-1")) == 0o700)
        #expect(mode(at: URL(fileURLWithPath: receipt.path)) == 0o600)
    }

    @Test("hostile advisory names cannot escape and keep only a supported extension")
    func sanitizesAdvisoryName() throws {
        let home = try TemporaryDirectory(prefix: "handoff-home")
        let input = try inputDescriptor(Data("x".utf8))
        defer { close(input) }

        let receipt = try HandoffReceiver.receive(
            session: "session-2",
            advisoryName: "../../\u{202e}secret.MARKDOWN",
            expectedBytes: 1,
            inputDescriptor: input,
            homeDirectory: home.url
        )
        let name = URL(fileURLWithPath: receipt.path).lastPathComponent
        #expect(!name.contains(".."))
        #expect(name.hasSuffix(".markdown"))
    }

    @Test("same advisory name never overwrites an earlier receive")
    func sameNameReceivesAreUnique() throws {
        let home = try TemporaryDirectory(prefix: "handoff-home")
        let firstInput = try inputDescriptor(Data("first".utf8))
        defer { close(firstInput) }
        let first = try HandoffReceiver.receive(
            session: "session-3", advisoryName: "image.png", expectedBytes: 5,
            inputDescriptor: firstInput, homeDirectory: home.url
        )

        let secondInput = try inputDescriptor(Data("second".utf8))
        defer { close(secondInput) }
        let second = try HandoffReceiver.receive(
            session: "session-3", advisoryName: "image.png", expectedBytes: 6,
            inputDescriptor: secondInput, homeDirectory: home.url
        )

        #expect(first.path != second.path)
        #expect(try Data(contentsOf: URL(fileURLWithPath: first.path)) == Data("first".utf8))
        #expect(try Data(contentsOf: URL(fileURLWithPath: second.path)) == Data("second".utf8))
    }

    @Test("concurrent same-name receives publish distinct files")
    func concurrentSameNameReceivesAreUnique() async throws {
        let home = try TemporaryDirectory(prefix: "handoff-home")
        let receipts = try await withThrowingTaskGroup(of: HandoffReceiver.Receipt.self) { group in
            for index in 0..<8 {
                group.addTask {
                    let payload = Data("payload-\(index)".utf8)
                    let input = try inputDescriptor(payload)
                    defer { close(input) }
                    return try HandoffReceiver.receive(
                        session: "session-concurrent", advisoryName: "notes.md",
                        expectedBytes: payload.count, inputDescriptor: input,
                        homeDirectory: home.url
                    )
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }

        #expect(Set(receipts.map(\.path)).count == receipts.count)
        #expect(receipts.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test("second publish under a forced name collision throws publishFailed and leaves no temporary")
    func secondPublishWithSameNameFailsCleanly() throws {
        let home = try TemporaryDirectory(prefix: "handoff-home")
        let fixed = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let payload = Data("hello".utf8)

        func receiveOnce() throws -> HandoffReceiver.Receipt {
            let input = try inputDescriptor(payload)
            defer { close(input) }
            return try HandoffReceiver.receive(
                session: "session-collision", advisoryName: "note.md", expectedBytes: payload.count,
                inputDescriptor: input, homeDirectory: home.url, makeUUID: { fixed }
            )
        }

        _ = try receiveOnce()
        #expect(throws: HandoffReceiver.ReceiveError.publishFailed) {
            _ = try receiveOnce()
        }
        let sessionDir = home.url.appendingPathComponent(".awesomux/handoffs/session-collision")
        let leftovers = try FileManager.default
            .contentsOfDirectory(atPath: sessionDir.path)
            .filter { $0.hasPrefix(".handoff-") }
        #expect(leftovers.isEmpty)
    }

    @Test(
        "early EOF and extra bytes leave no temporary or final file",
        arguments: [
            (Data("abc".utf8), 4),
            (Data("abcde".utf8), 4),
        ])
    func rejectsWrongByteCount(payload: Data, expectedBytes: Int) throws {
        let home = try TemporaryDirectory(prefix: "handoff-home")
        let input = try inputDescriptor(payload)
        defer { close(input) }

        #expect(throws: HandoffReceiver.ReceiveError.self) {
            try HandoffReceiver.receive(
                session: "session-4", advisoryName: "notes.md", expectedBytes: expectedBytes,
                inputDescriptor: input, homeDirectory: home.url
            )
        }
        let directory = home.url.appendingPathComponent(".awesomux/handoffs/session-4")
        #expect((try FileManager.default.contentsOfDirectory(atPath: directory.path)).isEmpty)
    }

    @Test("symlink and non-private directory custody are rejected")
    func rejectsUnsafeDirectoryCustody() throws {
        let symlinkHome = try TemporaryDirectory(prefix: "handoff-home")
        let outside = try TemporaryDirectory(prefix: "handoff-outside")
        try FileManager.default.createSymbolicLink(
            at: symlinkHome.url.appendingPathComponent(".awesomux"),
            withDestinationURL: outside.url
        )
        let firstInput = try inputDescriptor(Data())
        defer { close(firstInput) }
        #expect(throws: HandoffReceiver.ReceiveError.unsafeDirectory) {
            try HandoffReceiver.receive(
                session: "session-5", advisoryName: "empty.md", expectedBytes: 0,
                inputDescriptor: firstInput, homeDirectory: symlinkHome.url
            )
        }

        let modeHome = try TemporaryDirectory(prefix: "handoff-home")
        let owned = modeHome.url.appendingPathComponent(".awesomux")
        try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: owned.path)
        let secondInput = try inputDescriptor(Data())
        defer { close(secondInput) }
        #expect(throws: HandoffReceiver.ReceiveError.unsafeDirectory) {
            try HandoffReceiver.receive(
                session: "session-6", advisoryName: "empty.md", expectedBytes: 0,
                inputDescriptor: secondInput, homeDirectory: modeHome.url
            )
        }

        let ownerHome = try TemporaryDirectory(prefix: "handoff-home")
        let thirdInput = try inputDescriptor(Data())
        defer { close(thirdInput) }
        #expect(throws: HandoffReceiver.ReceiveError.unsafeDirectory) {
            try HandoffReceiver.receive(
                session: "session-7", advisoryName: "empty.md", expectedBytes: 0,
                inputDescriptor: thirdInput, homeDirectory: ownerHome.url,
                effectiveUID: geteuid() + 1
            )
        }
    }

    private func inputDescriptor(_ data: Data) throws -> Int32 {
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { throw CocoaError(.fileReadUnknown) }
        if !data.isEmpty {
            let wrote = data.withUnsafeBytes { write(descriptors[1], $0.baseAddress, data.count) }
            guard wrote == data.count else {
                close(descriptors[0]); close(descriptors[1])
                throw CocoaError(.fileWriteUnknown)
            }
        }
        close(descriptors[1])
        return descriptors[0]
    }

    private func mode(at url: URL) -> mode_t? {
        var status = stat()
        guard lstat(url.path, &status) == 0 else { return nil }
        return status.st_mode & 0o777
    }
}
