import AwesoMuxTestSupport
import Darwin
import Foundation
import Testing
@testable import SecureFileIO

@Suite("SecureFileReader")
struct SecureFileReaderTests {
    @Test("reads from the opened descriptor after the path is replaced")
    func readsFromOpenedDescriptorAfterPathReplacement() throws {
        let temporaryDirectory = try TemporaryDirectory(prefix: "awesomux-secure-read")
        let directory = temporaryDirectory.url
        defer { withExtendedLifetime(temporaryDirectory) {} }

        let file = directory.appending(path: "document.md")
        let replacement = directory.appending(path: "replacement.md")
        try Data("original".utf8).write(to: file)
        try Data("replacement".utf8).write(to: replacement)

        let result = try SecureFileReader.read(
            at: file,
            maximumBytes: 64,
            afterOpen: {
                try FileManager.default.removeItem(at: file)
                try FileManager.default.moveItem(at: replacement, to: file)
            }
        )

        #expect(result.data == Data("original".utf8))
        #expect(try Data(contentsOf: file) == Data("replacement".utf8))
    }

    @Test("readPrefix crosses multiple 64 KiB chunks without cross-read contamination")
    func readPrefixCrossesMultipleChunksWithoutCrossReadContamination() throws {
        let temporaryDirectory = try TemporaryDirectory(prefix: "awesomux-secure-chunked")
        let directory = temporaryDirectory.url
        defer { withExtendedLifetime(temporaryDirectory) {} }
        let file = directory.appending(path: "chunked.bin")

        // One full 64 KiB chunk plus a short tail: the read loop must run
        // more than once against a reused buffer, and the final pass must be
        // shorter than the first so a stale-tail leak shows up as extra or
        // shifted bytes rather than passing silently.
        let totalBytes = 64 * 1024 + 100
        var pattern = Data(capacity: totalBytes)
        for index in 0..<totalBytes {
            pattern.append(UInt8((index * 7 + 13) % 251))
        }
        try pattern.write(to: file)

        let handle = try SecureFileReader.open(at: file)
        let prefix = try handle.readPrefix(maximumBytes: 200_000)

        #expect(prefix == pattern)
        #expect(prefix.count == totalBytes)
    }

    @Test("rejects growth past the byte cap after opening")
    func rejectsGrowthPastByteCapAfterOpening() throws {
        let temporaryDirectory = try TemporaryDirectory(prefix: "awesomux-secure-read")
        let directory = temporaryDirectory.url
        defer { withExtendedLifetime(temporaryDirectory) {} }
        let file = directory.appending(path: "config.toml")
        try Data("1234".utf8).write(to: file)

        #expect(throws: SecureFileReadError.tooLarge) {
            _ = try SecureFileReader.read(
                at: file,
                maximumBytes: 4,
                afterOpen: {
                    let handle = try FileHandle(forWritingTo: file)
                    try handle.seekToEnd()
                    try handle.write(contentsOf: Data("5".utf8))
                    try handle.close()
                }
            )
        }
    }

    @Test("opens a supported symlink target with close-on-exec")
    func opensSymlinkTargetWithCloseOnExec() throws {
        let temporaryDirectory = try TemporaryDirectory(prefix: "awesomux-secure-read")
        let directory = temporaryDirectory.url
        defer { withExtendedLifetime(temporaryDirectory) {} }
        let target = directory.appending(path: "target.md")
        let symlink = directory.appending(path: "document.md")
        try Data("content".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            atPath: symlink.path,
            withDestinationPath: target.lastPathComponent
        )

        let handle = try SecureFileReader.open(at: symlink)

        #expect(handle.resolvedURL.lastPathComponent == target.lastPathComponent)
        #expect(handle.isCloseOnExec)
        #expect(try handle.read(maximumBytes: 7) == Data("content".utf8))
    }

    @Test("strict policy rejects a final-component symlink without touching its target")
    func strictPolicyRejectsFinalComponentSymlink() throws {
        let temporaryDirectory = try TemporaryDirectory(prefix: "awesomux-secure-read")
        let directory = temporaryDirectory.url
        defer { withExtendedLifetime(temporaryDirectory) {} }
        let target = directory.appending(path: "target.json")
        let symlink = directory.appending(path: "session-state.json")
        let targetData = Data("preserve me".utf8)
        try targetData.write(to: target)
        try FileManager.default.createSymbolicLink(
            atPath: symlink.path,
            withDestinationPath: target.lastPathComponent
        )

        #expect(throws: SecureFileReadError.unreadable) {
            _ = try SecureFileReader.open(
                at: symlink,
                symlinkPolicy: .rejectFinalComponent
            )
        }
        #expect(try Data(contentsOf: target) == targetData)
        #expect(FileManager.default.fileExists(atPath: symlink.path))
    }

    @Test("rejects a sparse oversized file before reading")
    func rejectsSparseOversizedFileBeforeReading() throws {
        let temporaryDirectory = try TemporaryDirectory(prefix: "awesomux-secure-read")
        let directory = temporaryDirectory.url
        defer { withExtendedLifetime(temporaryDirectory) {} }
        let file = directory.appending(path: "oversized.toml")
        _ = FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 1024 * 1024 * 1024)
        try handle.close()

        #expect(throws: SecureFileReadError.tooLarge) {
            _ = try SecureFileReader.read(at: file, maximumBytes: 256 * 1024)
        }
    }

    @Test("rejects a regular file owned by a different effective user")
    func rejectsWrongOwner() throws {
        let temporaryDirectory = try TemporaryDirectory(prefix: "awesomux-secure-read")
        let directory = temporaryDirectory.url
        defer { withExtendedLifetime(temporaryDirectory) {} }
        let file = directory.appending(path: "session-state.json")
        try Data("content".utf8).write(to: file)

        #expect(throws: SecureFileReadError.wrongOwner) {
            _ = try SecureFileReader.open(
                at: file,
                effectiveUID: geteuid() + 1
            )
        }
    }

    @Test("rejects a FIFO without blocking")
    func rejectsFIFOWithoutBlocking() throws {
        let temporaryDirectory = try TemporaryDirectory(prefix: "awesomux-secure-read")
        let directory = temporaryDirectory.url
        defer { withExtendedLifetime(temporaryDirectory) {} }
        let fifo = directory.appending(path: "pipe.md")
        try #require(mkfifo(fifo.path, 0o600) == 0)

        #expect(throws: SecureFileReadError.notRegularFile) {
            _ = try SecureFileReader.open(at: fifo)
        }
    }

    @Test("rejects a symlink to a device")
    func rejectsSymlinkToDevice() throws {
        let temporaryDirectory = try TemporaryDirectory(prefix: "awesomux-secure-read")
        let directory = temporaryDirectory.url
        defer { withExtendedLifetime(temporaryDirectory) {} }
        let symlink = directory.appending(path: "device.md")
        try FileManager.default.createSymbolicLink(
            at: symlink,
            withDestinationURL: URL(fileURLWithPath: "/dev/null")
        )

        #expect(throws: SecureFileReadError.notRegularFile) {
            _ = try SecureFileReader.open(at: symlink)
        }
    }

    // MARK: - Suffix reads

    private func openedHandle(containing bytes: String) throws -> (
        SecureFileReadHandle, TemporaryDirectory
    ) {
        let temporaryDirectory = try TemporaryDirectory(prefix: "awesomux-secure-suffix")
        let file = temporaryDirectory.url.appending(path: "tail.md")
        try Data(bytes.utf8).write(to: file)
        return (try SecureFileReader.open(at: file), temporaryDirectory)
    }

    @Test(arguments: [
        ("abcdefghij", 4, "ghij", UInt64(6), UInt8(ascii: "f")),
        ("abcdefghij", 1, "j", 9, UInt8(ascii: "i")),
        ("ab\ncdef", 4, "cdef", 3, UInt8(ascii: "\n")),
        ("ab\ncdef", 5, "\ncdef", 2, UInt8(ascii: "b")),
        ("ab\ncdef", 99, "ab\ncdef", 0, nil),
        ("abc", 3, "abc", 0, nil), ("abc", 4096, "abc", 0, nil),
        ("abc", 0, "", 3, UInt8(ascii: "c")), ("abc", -1, "", 0, nil),
    ])
    func suffixWindow(input: String, limit: Int, expected: String, offset: UInt64, preceding: UInt8?) throws {
        let (handle, directory) = try openedHandle(containing: input)
        defer { withExtendedLifetime(directory) {} }
        if limit < 0 {
            #expect(throws: SecureFileReadError.unreadable) { _ = try handle.readSuffix(maximumBytes: limit) }
        } else {
            #expect(try handle.readSuffix(maximumBytes: limit) == (Data(expected.utf8), offset, preceding))
        }
    }

    @Test(arguments: [
        ("abcdefghij", "abc", 64, "abc", UInt64(0), UInt8?.none),
        (String(repeating: "x", count: 4096), "abcdefghij", 4, "ghij", 6, UInt8(ascii: "f")),
        ("abcdef", "abcdefXYZ", 3, "def", 3, UInt8(ascii: "c")),
    ])
    func suffixFollowsFileChanges(initial: String, changed: String, limit: Int, expected: String, offset: UInt64, preceding: UInt8?) throws
    {
        let directory = try TemporaryDirectory(prefix: "awesomux-secure-suffix")
        let file = directory.url.appending(path: "changing.md")
        defer { withExtendedLifetime(directory) {} }
        try Data(initial.utf8).write(to: file)
        let handle = try SecureFileReader.open(at: file)
        let writer = try FileHandle(forWritingTo: file)
        if changed.hasPrefix(initial) {
            try writer.seekToEnd()
            try writer.write(contentsOf: Data(changed.dropFirst(initial.count).utf8))
        } else {
            try writer.truncate(atOffset: 0)
            try writer.write(contentsOf: Data(changed.utf8))
        }
        try writer.close()
        #expect(try handle.readSuffix(maximumBytes: limit) == (Data(expected.utf8), offset, preceding))
        #expect(handle.size == initial.utf8.count)
    }

}
