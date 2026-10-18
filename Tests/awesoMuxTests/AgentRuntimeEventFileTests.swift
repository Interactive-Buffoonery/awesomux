import Darwin
import Foundation
import Testing
@testable import awesoMux

@Suite("Agent runtime event file preparation")
struct AgentRuntimeEventFileTests {
    @Test(arguments: [false, true])
    func preparesPrivateEventFile(existing: Bool) throws {
        try Self.withTemporaryDirectory { directory in
            let file = directory.appending(path: "events.jsonl")
            if existing {
                FileManager.default.createFile(atPath: file.path, contents: nil)
                try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
            }
            #expect(AgentRuntimeEventFile.prepare(at: file))
            let info = try Self.fileInfo(at: file)
            #expect(info.isRegularFile)
            #expect(info.permissions == 0o600)
            #expect(info.ownerUID == geteuid())
        }
    }

    @Test(arguments: ["prepare-symlink", "prepare-directory", "truncate-symlink", "read-symlink"])
    func rejectsUnsafeEventPath(scenario: String) throws {
        try Self.withTemporaryDirectory { directory in
            let target = directory.appending(path: "target.jsonl")
            let file = directory.appending(path: "events.jsonl")
            let contents = scenario == "read-symlink" ? #"{"v":1,"source":"codex","execution":"thinking"}"# : "sentinel"
            if scenario == "prepare-directory" {
                try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
            } else {
                try Data(contents.utf8).write(to: target)
                try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
            }
            switch scenario {
            case "truncate-symlink":
                #expect(AgentRuntimeEventFile.truncate(at: file) == .rotationRequired)
            case "read-symlink":
                #expect(AgentRuntimeEventFile.openForReading(at: file) == nil)
            default:
                #expect(!AgentRuntimeEventFile.prepare(at: file))
            }
            if scenario == "prepare-directory" {
                #expect(try Self.fileInfo(at: file).isDirectory)
            } else {
                #expect(try String(contentsOf: target, encoding: .utf8) == contents)
                #expect(Self.isSymbolicLink(file))
            }
        }
    }

    @Test(arguments: ["prepare", "truncate", "read"])
    func rejectsWrongOwner(operation: String) throws {
        try Self.withTemporaryDirectory { directory in
            let file = directory.appending(path: "events.jsonl")
            let contents = operation == "truncate" ? "stale" : operation == "read" ? "event" : ""
            try Data(contents.utf8).write(to: file)
            switch operation {
            case "prepare":
                #expect(!AgentRuntimeEventFile.prepare(at: file, effectiveUID: geteuid() + 1))
            case "truncate":
                #expect(AgentRuntimeEventFile.truncate(at: file, effectiveUID: geteuid() + 1) == .rotationRequired)
                #expect(try Data(contentsOf: file) == Data("stale".utf8))
            default:
                #expect(AgentRuntimeEventFile.openForReading(at: file, effectiveUID: geteuid() + 1) == nil)
            }
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
