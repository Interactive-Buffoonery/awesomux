import Foundation
import Testing
@testable import AwesoMuxTestSupport

@Suite("Temporary directory")
struct TemporaryDirectoryTests {
    @Test("creates a unique system folder and removes its exact path")
    func createsAndCleansUp() throws {
        var directory: TemporaryDirectory? = try TemporaryDirectory(prefix: "awesomux-test")
        let url = try #require(directory?.url)
        let sibling = url.deletingLastPathComponent().appending(path: "keep-" + UUID().uuidString)
        try Data().write(to: sibling)
        defer { try? FileManager.default.removeItem(at: sibling) }

        #expect(FileManager.default.fileExists(atPath: url.path))
        directory = nil
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(FileManager.default.fileExists(atPath: sibling.path))
    }
}
