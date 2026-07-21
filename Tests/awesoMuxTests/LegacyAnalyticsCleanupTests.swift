import Foundation
import Testing
@testable import awesoMux

@Suite("Legacy analytics cleanup")
struct LegacyAnalyticsCleanupTests {
    @Test("missing legacy analytics data is a no-op")
    func missingLegacyDataIsNoOp() throws {
        let supportDirectory = try makeSupportDirectory()
        defer { try? FileManager.default.removeItem(at: supportDirectory) }

        try LegacyAnalyticsCleanup.removeData(in: supportDirectory)

        #expect(FileManager.default.fileExists(atPath: supportDirectory.path))
    }

    @Test("legacy analytics directory and contents are removed")
    func legacyDirectoryIsRemoved() throws {
        let supportDirectory = try makeSupportDirectory()
        defer { try? FileManager.default.removeItem(at: supportDirectory) }
        let analyticsDirectory = supportDirectory.appending(
            path: "analytics",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: analyticsDirectory,
            withIntermediateDirectories: false
        )
        try Data("event\n".utf8).write(to: analyticsDirectory.appending(path: "events.jsonl"))
        try Data("legacy-id".utf8).write(to: analyticsDirectory.appending(path: "distinct_id"))

        try LegacyAnalyticsCleanup.removeData(in: supportDirectory)

        #expect(!FileManager.default.fileExists(atPath: analyticsDirectory.path))
        #expect(FileManager.default.fileExists(atPath: supportDirectory.path))
    }

    private func makeSupportDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(
            path: "awesomux-legacy-analytics-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
}
