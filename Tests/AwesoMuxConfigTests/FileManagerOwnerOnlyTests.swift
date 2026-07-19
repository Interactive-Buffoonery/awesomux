import Foundation
import Testing
@testable import AwesoMuxConfig

@Suite("FileManager owner-only helpers")
struct FileManagerOwnerOnlyTests {
    private let fileManager = FileManager.default

    private func makeScratchDirectory() throws -> URL {
        let url = fileManager.temporaryDirectory
            .appending(path: "owner-only-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func permissions(atPath path: String) throws -> Int {
        let attributes = try fileManager.attributesOfItem(atPath: path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    @Test("creates directory and intermediates with owner-only permissions")
    func createsOwnerOnlyDirectory() throws {
        let scratch = try makeScratchDirectory()
        defer { try? fileManager.removeItem(at: scratch) }
        let intermediate = scratch.appending(path: "intermediate", directoryHint: .isDirectory)
        let nested = intermediate.appending(path: "leaf", directoryHint: .isDirectory)

        try fileManager.createOwnerOnlyDirectory(at: nested)

        #expect(try permissions(atPath: nested.path) == 0o700)
        #expect(try permissions(atPath: intermediate.path) == 0o700)
    }

    @Test("creating an existing directory does not throw or re-clamp it")
    func creatingExistingDirectoryIsNoOp() throws {
        let scratch = try makeScratchDirectory()
        defer { try? fileManager.removeItem(at: scratch) }
        let directory = scratch.appending(path: "existing", directoryHint: .isDirectory)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o755]
        )

        try fileManager.createOwnerOnlyDirectory(at: directory)

        #expect(try permissions(atPath: directory.path) == 0o755)
    }

    @Test("clamps an existing directory to owner-only")
    func clampsDirectoryToOwnerOnly() throws {
        let scratch = try makeScratchDirectory()
        defer { try? fileManager.removeItem(at: scratch) }
        let directory = scratch.appending(path: "wide", directoryHint: .isDirectory)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o755]
        )

        try fileManager.setOwnerOnlyPermissions(onDirectoryAt: directory)

        #expect(try permissions(atPath: directory.path) == 0o700)
    }

    @Test("clamps an existing file to owner-only")
    func clampsFileToOwnerOnly() throws {
        let scratch = try makeScratchDirectory()
        defer { try? fileManager.removeItem(at: scratch) }
        let file = scratch.appending(path: "state.json")
        try Data("{}".utf8).write(to: file)
        try fileManager.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: file.path
        )

        try fileManager.setOwnerOnlyPermissions(onFileAt: file)

        #expect(try permissions(atPath: file.path) == 0o600)
    }

    @Test("clamping a missing item throws")
    func clampingMissingItemThrows() throws {
        let scratch = try makeScratchDirectory()
        defer { try? fileManager.removeItem(at: scratch) }
        let missing = scratch.appending(path: "missing.json")

        #expect(throws: (any Error).self) {
            try fileManager.setOwnerOnlyPermissions(onFileAt: missing)
        }
    }

    @Test("writes a new file at owner-only with no leftover temp file")
    func writesNewOwnerOnlyFile() throws {
        let scratch = try makeScratchDirectory()
        defer { try? fileManager.removeItem(at: scratch) }
        let file = scratch.appending(path: "events.jsonl")

        try fileManager.writeOwnerOnlyFile(at: file, contents: Data("hello\n".utf8))

        #expect(try Data(contentsOf: file) == Data("hello\n".utf8))
        #expect(try permissions(atPath: file.path) == 0o600)
        #expect(try fileManager.contentsOfDirectory(atPath: scratch.path) == ["events.jsonl"])
    }

    @Test("replacing an existing lax file ends at owner-only")
    func replacingLaxFileClampsToOwnerOnly() throws {
        let scratch = try makeScratchDirectory()
        defer { try? fileManager.removeItem(at: scratch) }
        let file = scratch.appending(path: "state.json")
        try Data("old".utf8).write(to: file)
        try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)

        try fileManager.writeOwnerOnlyFile(at: file, contents: Data("new".utf8))

        #expect(try Data(contentsOf: file) == Data("new".utf8))
        #expect(try permissions(atPath: file.path) == 0o600)
    }

    // Deliberately untested: the fchmod pin that holds 0o600 under a
    // restrictive umask. umask is process-global, so any in-process test
    // races the parallel suite (a 0o277 window broke sibling scratch
    // directories), and a sound check needs a spawned helper executable.
    // ConfigFileStore's original of this pattern (INT-539) carries the
    // same gap.

    @Test("a directory at the target path throws instead of being replaced")
    func writingOverDirectoryThrows() throws {
        let scratch = try makeScratchDirectory()
        defer { try? fileManager.removeItem(at: scratch) }
        let target = scratch.appending(path: "events.jsonl", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: target, withIntermediateDirectories: false)

        #expect(throws: (any Error).self) {
            try fileManager.writeOwnerOnlyFile(at: target, contents: Data())
        }
        var isDirectory: ObjCBool = false
        #expect(fileManager.fileExists(atPath: target.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }

    @Test("writing into a missing parent directory throws")
    func writingIntoMissingParentThrows() throws {
        let scratch = try makeScratchDirectory()
        defer { try? fileManager.removeItem(at: scratch) }
        let file = scratch.appending(path: "missing", directoryHint: .isDirectory)
            .appending(path: "state.json")

        #expect(throws: (any Error).self) {
            try fileManager.writeOwnerOnlyFile(at: file, contents: Data())
        }
    }
}
