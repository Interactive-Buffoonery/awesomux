import Darwin
import Foundation
import Testing
@testable import awesoMux

@Suite("Agent runtime event file preparation")
struct AgentRuntimeEventFileTests {
    @Test("missing event file is created with private permissions")
    func missingEventFileIsCreatedWithPrivatePermissions() throws {
        try Self.withTemporaryDirectory { directory in
            let file = directory.appending(path: "events.jsonl")

            #expect(AgentRuntimeEventFile.prepare(at: file))

            let info = try Self.fileInfo(at: file)
            #expect(info.isRegularFile)
            #expect(info.permissions == 0o600)
            #expect(info.ownerUID == geteuid())
        }
    }

    @Test("existing event file is chmodded by descriptor")
    func existingEventFileIsChmoddedByDescriptor() throws {
        try Self.withTemporaryDirectory { directory in
            let file = directory.appending(path: "events.jsonl")
            FileManager.default.createFile(atPath: file.path, contents: nil)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: file.path
            )

            #expect(AgentRuntimeEventFile.prepare(at: file))

            #expect(try Self.fileInfo(at: file).permissions == 0o600)
        }
    }

    @Test("symlink event path is rejected without touching target")
    func symlinkEventPathIsRejectedWithoutTouchingTarget() throws {
        try Self.withTemporaryDirectory { directory in
            let target = directory.appending(path: "target.jsonl")
            let link = directory.appending(path: "events.jsonl")
            try Data("sentinel".utf8).write(to: target)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

            #expect(!AgentRuntimeEventFile.prepare(at: link))

            #expect(try String(contentsOf: target, encoding: .utf8) == "sentinel")
            #expect(Self.isSymbolicLink(link))
        }
    }

    @Test("directory event path is rejected")
    func directoryEventPathIsRejected() throws {
        try Self.withTemporaryDirectory { directory in
            let eventDirectory = directory.appending(path: "events.jsonl", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: eventDirectory, withIntermediateDirectories: false)

            #expect(!AgentRuntimeEventFile.prepare(at: eventDirectory))
            #expect(try Self.fileInfo(at: eventDirectory).isDirectory)
        }
    }

    @Test("wrong owner directory is rejected")
    func wrongOwnerDirectoryIsRejected() throws {
        // `prepare` validates the directory owner before reaching the file, so a
        // mismatched effective UID fails at `prepareDirectory`. The file-owner
        // path is covered by `AgentHookEventFileAppender.validate` tests.
        try Self.withTemporaryDirectory { directory in
            let file = directory.appending(path: "events.jsonl")
            FileManager.default.createFile(atPath: file.path, contents: nil)

            #expect(!AgentRuntimeEventFile.prepare(at: file, effectiveUID: geteuid() + 1))
        }
    }

    @Test("truncate zeroes an existing event file in place")
    func truncateZeroesExistingFileInPlace() throws {
        try Self.withTemporaryDirectory { directory in
            let file = directory.appending(path: "events.jsonl")
            try Data("stale event data".utf8).write(to: file)
            let originalInode = try Self.inode(at: file)

            #expect(AgentRuntimeEventFile.truncate(at: file) == .truncatedInPlace)

            #expect(try Self.fileInfo(at: file).isRegularFile)
            #expect(try Data(contentsOf: file).isEmpty)
            #expect(try Self.inode(at: file) == originalInode)
        }
    }

    @Test("truncate rejects a symlink without touching its target")
    func truncateRejectsSymlinkWithoutTouchingTarget() throws {
        try Self.withTemporaryDirectory { directory in
            let target = directory.appending(path: "target.jsonl")
            let link = directory.appending(path: "events.jsonl")
            try Data("sentinel".utf8).write(to: target)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

            #expect(AgentRuntimeEventFile.truncate(at: link) == .rotationRequired)

            #expect(try String(contentsOf: target, encoding: .utf8) == "sentinel")
            #expect(Self.isSymbolicLink(link))
        }
    }

    @Test("truncate of a missing file requires rotation")
    func truncateOfMissingFileRequiresRotation() throws {
        try Self.withTemporaryDirectory { directory in
            let file = directory.appending(path: "events.jsonl")

            #expect(AgentRuntimeEventFile.truncate(at: file) == .rotationRequired)
        }
    }

    @Test("truncate rejects a wrong-owner file")
    func truncateRejectsWrongOwnerFile() throws {
        try Self.withTemporaryDirectory { directory in
            let file = directory.appending(path: "events.jsonl")
            try Data("stale".utf8).write(to: file)

            #expect(
                AgentRuntimeEventFile.truncate(at: file, effectiveUID: geteuid() + 1)
                    == .rotationRequired
            )
            #expect(try Data(contentsOf: file) == Data("stale".utf8))
        }
    }

    @Test("read handle reads from validated descriptor")
    func readHandleReadsFromValidatedDescriptor() throws {
        try Self.withTemporaryDirectory { directory in
            let file = directory.appending(path: "events.jsonl")
            let contents = Data("first\nsecond\n".utf8)
            try contents.write(to: file)

            let handle = try #require(AgentRuntimeEventFile.openForReading(at: file))

            #expect(handle.size == UInt64(contents.count))
            #expect(handle.inode == (try Self.inode(at: file)))
            #expect(handle.readData(from: 0) == contents)
            #expect(handle.readData(from: 6) == Data("second\n".utf8))
        }
    }

    @Test("read handle rejects symlink without reading target")
    func readHandleRejectsSymlinkWithoutReadingTarget() throws {
        try Self.withTemporaryDirectory { directory in
            let target = directory.appending(path: "target.jsonl")
            let link = directory.appending(path: "events.jsonl")
            let contents = #"{"v":1,"source":"codex","execution":"thinking"}"#
            try Data(contents.utf8).write(to: target)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

            #expect(AgentRuntimeEventFile.openForReading(at: link) == nil)

            #expect(try String(contentsOf: target, encoding: .utf8) == contents)
            #expect(Self.isSymbolicLink(link))
        }
    }

    @Test("read handle rejects wrong-owner file")
    func readHandleRejectsWrongOwnerFile() throws {
        try Self.withTemporaryDirectory { directory in
            let file = directory.appending(path: "events.jsonl")
            try Data("event".utf8).write(to: file)

            #expect(AgentRuntimeEventFile.openForReading(at: file, effectiveUID: geteuid() + 1) == nil)
        }
    }

    private static func inode(at url: URL) throws -> ino_t {
        var st = stat()
        guard lstat(url.path, &st) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return st.st_ino
    }

    private static func withTemporaryDirectory(_ operation: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "awesomux-runtime-event-file-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try operation(directory)
    }

    private static func fileInfo(at url: URL) throws -> FileInfo {
        var st = stat()
        guard lstat(url.path, &st) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return FileInfo(
            permissions: st.st_mode & 0o777,
            ownerUID: st.st_uid,
            isRegularFile: (st.st_mode & S_IFMT) == S_IFREG,
            isDirectory: (st.st_mode & S_IFMT) == S_IFDIR
        )
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        var st = stat()
        guard lstat(url.path, &st) == 0 else {
            return false
        }
        return (st.st_mode & S_IFMT) == S_IFLNK
    }

    private struct FileInfo {
        var permissions: mode_t
        var ownerUID: uid_t
        var isRegularFile: Bool
        var isDirectory: Bool
    }
}
