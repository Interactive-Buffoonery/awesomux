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

    @Test("reports close-on-exec as false when descriptor inspection fails")
    func reportsCloseOnExecAsFalseWhenDescriptorInspectionFails() {
        let result = SecureFileReadHandle.isCloseOnExec(
            descriptor: 42,
            getDescriptorFlags: { descriptor in
                #expect(descriptor == 42)
                return -1
            }
        )

        #expect(!result)
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

    @Test("readSuffix returns the last bytes of a longer file without rejecting it")
    func readSuffixReturnsTheTail() throws {
        let (handle, temporaryDirectory) = try openedHandle(containing: "abcdefghij")
        defer { withExtendedLifetime(temporaryDirectory) {} }

        #expect(try handle.readSuffix(maximumBytes: 4) == (Data("ghij".utf8), 6, UInt8(ascii: "f")))
        #expect(try handle.readSuffix(maximumBytes: 1) == (Data("j".utf8), 9, UInt8(ascii: "i")))
    }

    /// The one byte a line-oriented caller needs: without it, a window landing
    /// exactly on a separator is indistinguishable from one landing mid-record,
    /// and the whole first record gets discarded as a fragment.
    @Test("readSuffix reports the byte before the window, and nil at offset zero")
    func readSuffixReportsThePrecedingByte() throws {
        let (handle, temporaryDirectory) = try openedHandle(containing: "ab\ncdef")
        defer { withExtendedLifetime(temporaryDirectory) {} }

        #expect(try handle.readSuffix(maximumBytes: 4).precedingByte == UInt8(ascii: "\n"))
        #expect(try handle.readSuffix(maximumBytes: 5).precedingByte == UInt8(ascii: "b"))
        #expect(try handle.readSuffix(maximumBytes: 99).precedingByte == nil)
    }

    @Test("readSuffix returns the whole file when the window covers it")
    func readSuffixCoversShortFiles() throws {
        let (handle, temporaryDirectory) = try openedHandle(containing: "abc")
        defer { withExtendedLifetime(temporaryDirectory) {} }

        // A window at least as wide as the file starts at zero, and says so —
        // the only sound signal that no earlier bytes were skipped.
        #expect(try handle.readSuffix(maximumBytes: 3) == (Data("abc".utf8), 0, nil))
        #expect(try handle.readSuffix(maximumBytes: 4096) == (Data("abc".utf8), 0, nil))
        #expect(try handle.readSuffix(maximumBytes: 0) == (Data(), 3, UInt8(ascii: "c")))
    }

    @Test("readSuffix reports offset zero when the file shrank after it was opened")
    func readSuffixReportsZeroOffsetAfterTruncation() throws {
        let temporaryDirectory = try TemporaryDirectory(prefix: "awesomux-secure-suffix")
        defer { withExtendedLifetime(temporaryDirectory) {} }
        let file = temporaryDirectory.url.appending(path: "shrinking.md")
        try Data("abcdefghij".utf8).write(to: file)
        let handle = try SecureFileReader.open(at: file)

        let writeHandle = try FileHandle(forWritingTo: file)
        try writeHandle.truncate(atOffset: 3)
        try writeHandle.close()

        // The read starts at byte zero and comes back short. Inferring "earlier
        // bytes were skipped" from the stale `size` would be wrong here, which
        // is why the offset is reported rather than derived.
        let suffix = try handle.readSuffix(maximumBytes: 64)
        #expect(suffix.startOffset == 0)
        #expect(suffix.data == Data("abc".utf8))
        #expect(handle.size == 10)
    }

    @Test("readSuffix rejects a negative window")
    func readSuffixRejectsNegativeWindow() throws {
        let (handle, temporaryDirectory) = try openedHandle(containing: "abc")
        defer { withExtendedLifetime(temporaryDirectory) {} }

        #expect(throws: SecureFileReadError.unreadable) {
            _ = try handle.readSuffix(maximumBytes: -1)
        }
    }

    @Test("readSuffix ignores bytes appended after the descriptor was validated")
    func readSuffixIgnoresLaterGrowth() throws {
        let temporaryDirectory = try TemporaryDirectory(prefix: "awesomux-secure-suffix")
        defer { withExtendedLifetime(temporaryDirectory) {} }
        let file = temporaryDirectory.url.appending(path: "growing.md")
        try Data("abcdef".utf8).write(to: file)
        let handle = try SecureFileReader.open(at: file)

        let writeHandle = try FileHandle(forWritingTo: file)
        try writeHandle.seekToEnd()
        try writeHandle.write(contentsOf: Data("XYZ".utf8))
        try writeHandle.close()

        // The window is anchored to the validated size, so the appended bytes
        // shift into the window rather than extending it.
        #expect(try handle.readSuffix(maximumBytes: 3) == (Data("def".utf8), 3, UInt8(ascii: "c")))
    }

    /// The stale-size trap, and the worst of the empty-document routes: with the
    /// window anchored to the size captured at `open`, a file that shrank below
    /// `start` reads NOTHING from a non-zero offset — an empty result that every
    /// caller reads as "earlier bytes were skipped", so a transcript renders as
    /// blank *and* claims turns were omitted while its whole content sits at
    /// offset zero (review finding).
    @Test("readSuffix follows a file that shrank below the window's start offset")
    func readSuffixFollowsAFileThatShrankBelowTheWindowStart() throws {
        let temporaryDirectory = try TemporaryDirectory(prefix: "awesomux-secure-suffix")
        defer { withExtendedLifetime(temporaryDirectory) {} }
        let file = temporaryDirectory.url.appending(path: "shrinking.jsonl")
        try Data(String(repeating: "x", count: 4096).utf8).write(to: file)
        let handle = try SecureFileReader.open(at: file)

        let writeHandle = try FileHandle(forWritingTo: file)
        try writeHandle.truncate(atOffset: 0)
        try writeHandle.write(contentsOf: Data("abcdefghij".utf8))
        try writeHandle.close()

        let suffix = try handle.readSuffix(maximumBytes: 4)
        #expect(suffix.data == Data("ghij".utf8))
        #expect(suffix.startOffset == 6)
        #expect(handle.size == 4096, "the validated size still reports what was opened")
    }
}
