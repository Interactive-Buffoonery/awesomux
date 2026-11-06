import Foundation
import Testing

@testable import awesoMux

@Suite("Generated document prune ordering")
struct GeneratedDocumentCacheTests {
    @Test(arguments: [false, true])
    func completedPruneProtectsNewWriteFromOlderPrune(reversed: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.trashItem(at: directory, resultingItemURL: nil) }
        let first = GeneratedDocumentCache(cacheDirectoryURL: directory, fileNameSuffix: ".generated.md")
        let second = GeneratedDocumentCache(
            cacheDirectoryURL: directory.appending(path: "."), fileNameSuffix: ".generated.md"
        )
        let older = first.pruneOperation(keeping: [])
        let file = try #require(first.write("live document", cacheIdentityKey: "live"))
        first.completeWrite(at: file)
        let newer = second.pruneOperation(keeping: [file])

        if reversed {
            newer()
            older()
        } else {
            older()
            newer()
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == "live document")

        second.pruneUnreferencedImmediately(keeping: [])
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test
    func completedPruneInAnotherDirectoryDoesNotSkipCollection() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.trashItem(at: root, resultingItemURL: nil) }
        let first = GeneratedDocumentCache(
            cacheDirectoryURL: root.appending(path: "first"), fileNameSuffix: ".generated.md"
        )
        let second = GeneratedDocumentCache(
            cacheDirectoryURL: root.appending(path: "second"), fileNameSuffix: ".generated.md"
        )
        let file = try #require(first.write("unreferenced", cacheIdentityKey: "old"))
        first.completeWrite(at: file)
        first.pruneUnreferencedImmediately(keeping: [file])
        let older = first.pruneOperation(keeping: [])
        _ = try #require(second.write("other", cacheIdentityKey: "other"))
        second.pruneUnreferencedImmediately(keeping: [])
        older()
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test
    func failedEnumerationDoesNotSupersedeOlderPrune() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.trashItem(at: root, resultingItemURL: nil) }
        let directory = root.appending(path: "cache")
        let moved = root.appending(path: "moved")
        let cache = GeneratedDocumentCache(cacheDirectoryURL: directory, fileNameSuffix: ".generated.md")
        let file = try #require(cache.write("unreferenced", cacheIdentityKey: "old"))
        cache.completeWrite(at: file)
        cache.pruneUnreferencedImmediately(keeping: [file])
        let older = cache.pruneOperation(keeping: [])
        let newer = cache.pruneOperation(keeping: [file])
        try FileManager.default.moveItem(at: directory, to: moved)
        newer()
        try FileManager.default.moveItem(at: moved, to: directory)
        older()
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test
    func failedDeletionKeepsWriteProtectionAndOlderPruneEligible() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.trashItem(at: directory, resultingItemURL: nil) }
        let cache = GeneratedDocumentCache(cacheDirectoryURL: directory, fileNameSuffix: ".generated.md")
        let older = cache.pruneOperation(keeping: [])
        let live = try #require(cache.write("live", cacheIdentityKey: "live"))
        cache.completeWrite(at: live)
        let foreign = directory.appending(path: "foreign.md")
        try Data("unreferenced".utf8).write(to: foreign)
        let failing = GeneratedDocumentCache(
            cacheDirectoryURL: directory, fileNameSuffix: ".generated.md", fileManager: DeletionFailingFileManager()
        )
        failing.pruneUnreferencedImmediately(keeping: [live])
        older()
        #expect(try String(contentsOf: live, encoding: .utf8) == "live")
        #expect(!FileManager.default.fileExists(atPath: foreign.path))
    }

    @Test
    func failedEntryDoesNotPreventLaterCollection() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.trashItem(at: directory, resultingItemURL: nil) }
        let cache = GeneratedDocumentCache(cacheDirectoryURL: directory, fileNameSuffix: ".generated.md")
        let older = cache.pruneOperation(keeping: [])
        let live = try #require(cache.write("live", cacheIdentityKey: "live"))
        cache.completeWrite(at: live)
        let blocked = directory.appending(path: "a-blocked.md")
        let collectible = directory.appending(path: "b-collectible.md")
        try Data("blocked".utf8).write(to: blocked)
        try Data("collectible".utf8).write(to: collectible)
        let failing = GeneratedDocumentCache(
            cacheDirectoryURL: directory, fileNameSuffix: ".generated.md", fileManager: SelectiveDeletionFailingFileManager()
        )

        failing.pruneUnreferencedImmediately(keeping: [live])
        #expect(FileManager.default.fileExists(atPath: blocked.path))
        #expect(!FileManager.default.fileExists(atPath: collectible.path))
        older()
        #expect(!FileManager.default.fileExists(atPath: blocked.path))
        #expect(try String(contentsOf: live, encoding: .utf8) == "live")
        cache.pruneUnreferencedImmediately(keeping: [live])
        cache.pruneUnreferencedImmediately(keeping: [])
        #expect(!FileManager.default.fileExists(atPath: live.path))
    }

}

private final class DeletionFailingFileManager: FileManager, @unchecked Sendable {
    override func removeItem(at URL: URL) throws {
        throw CocoaError(.fileWriteNoPermission)
    }
}

private final class SelectiveDeletionFailingFileManager: FileManager, @unchecked Sendable {
    override func contentsOfDirectory(
        at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?, options mask: FileManager.DirectoryEnumerationOptions = []
    ) throws -> [URL] {
        try super.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: mask)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    override func removeItem(at url: URL) throws {
        guard url.lastPathComponent != "a-blocked.md" else { throw CocoaError(.fileWriteNoPermission) }
        try super.removeItem(at: url)
    }
}
