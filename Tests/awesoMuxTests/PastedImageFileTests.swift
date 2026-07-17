import AwesoMuxTestSupport
import Foundation
import Testing
@testable import awesoMux

@Suite("Pasted image cleanup")
struct PastedImageFileTests {
    @Test("cleanup deletes only PNG files older than the cutoff")
    func deletesOnlyOldPNGs() throws {
        let directory = try TemporaryDirectory(prefix: "pasted-image-cleanup")
        let oldPNG = directory.url.appendingPathComponent("old.png")
        let newPNG = directory.url.appendingPathComponent("new.PNG")
        let oldText = directory.url.appendingPathComponent("old.txt")
        for url in [oldPNG, newPNG, oldText] {
            try Data("fixture".utf8).write(to: url)
        }

        let cutoff = Date()
        try FileManager.default.setAttributes(
            [.modificationDate: cutoff.addingTimeInterval(-60)],
            ofItemAtPath: oldPNG.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: cutoff.addingTimeInterval(60)],
            ofItemAtPath: newPNG.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: cutoff.addingTimeInterval(-60)],
            ofItemAtPath: oldText.path
        )

        PastedImageFile.cleanup(olderThan: cutoff, in: directory.url)

        #expect(!FileManager.default.fileExists(atPath: oldPNG.path))
        #expect(FileManager.default.fileExists(atPath: newPNG.path))
        #expect(FileManager.default.fileExists(atPath: oldText.path))
    }

    @Test("cleanup tolerates a missing directory")
    func missingDirectoryIsSafe() throws {
        let directory = try TemporaryDirectory(prefix: "pasted-image-cleanup-missing")
        let missing = directory.url.appendingPathComponent("missing", isDirectory: true)

        PastedImageFile.cleanup(olderThan: Date(), in: missing)

        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }
}
