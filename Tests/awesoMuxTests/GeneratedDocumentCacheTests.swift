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
}
