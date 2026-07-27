import Darwin
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

    @Test("writes a new file at 0600 without inheriting the ambient umask")
    func writesNewOwnerOnlyFileAtExactMode() throws {
        let scratch = try makeScratchDirectory()
        defer { try? fileManager.removeItem(at: scratch) }
        let file = scratch.appending(path: "state.json")

        // Deliberately does NOT call `umask()`. That is process-global, and
        // this suite runs in parallel with every other — a temporarily
        // widened mask would leak into unrelated tests' file creation, and
        // `defer` cannot close that window because the race is *inside* it.
        //
        // Instead, prove the ambient mask is permissive enough for the
        // assertion below to mean anything: a plainly-written sibling must
        // NOT already be 0600. Under the usual 0o022 it lands at 0644, so the
        // real assertion can distinguish a correct write from a
        // write-then-chmod one. Under a restrictive ambient mask (0o077) it
        // would land at 0600 on its own and the real assertion would pass for
        // the wrong reason — this control fails loudly instead of quietly
        // becoming vacuous.
        let control = scratch.appending(path: "control.json")
        try Data("{}".utf8).write(to: control)
        #expect(
            try permissions(atPath: control.path) != 0o600,
            """
            ambient umask is too restrictive for this test to be meaningful — \
            a plain write already produced 0600, so the assertion below cannot \
            tell a correct implementation from a write-then-chmod one
            """
        )

        try fileManager.writeOwnerOnlyFile(at: file, contents: Data("{}".utf8))

        #expect(try permissions(atPath: file.path) == 0o600)
        #expect(try Data(contentsOf: file) == Data("{}".utf8))
        // Exactly the control and the written file — still proves the
        // temporary file was renamed away rather than left behind.
        #expect(
            try fileManager.contentsOfDirectory(atPath: scratch.path).sorted()
                == ["control.json", "state.json"]
        )
    }

    @Test("replacing an existing file swaps its contents and re-clamps the mode")
    func writesOwnerOnlyFileReplacingExistingFile() throws {
        let scratch = try makeScratchDirectory()
        defer { try? fileManager.removeItem(at: scratch) }
        let file = scratch.appending(path: "state.json")
        try Data("stale".utf8).write(to: file)
        try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)

        try fileManager.writeOwnerOnlyFile(at: file, contents: Data("fresh".utf8))

        #expect(try Data(contentsOf: file) == Data("fresh".utf8))
        #expect(try permissions(atPath: file.path) == 0o600)
        #expect(try fileManager.contentsOfDirectory(atPath: scratch.path) == ["state.json"])
    }

    @Test("a failed write leaves no temporary file behind")
    func failedOwnerOnlyWriteRemovesTemporaryFile() throws {
        let scratch = try makeScratchDirectory()
        defer { try? fileManager.removeItem(at: scratch) }
        // rename(2) refuses to replace a non-empty directory, so the write fails
        // only after the temporary file exists — the case the cleanup guards.
        let occupied = scratch.appending(path: "occupied", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: occupied, withIntermediateDirectories: false)
        try Data("child".utf8).write(to: occupied.appending(path: "child"))

        #expect(throws: (any Error).self) {
            try fileManager.writeOwnerOnlyFile(at: occupied, contents: Data("{}".utf8))
        }

        #expect(try fileManager.contentsOfDirectory(atPath: scratch.path) == ["occupied"])
    }
}
