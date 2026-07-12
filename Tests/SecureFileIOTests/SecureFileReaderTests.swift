import Darwin
import Foundation
import Testing
@testable import SecureFileIO

@Suite("SecureFileReader")
struct SecureFileReaderTests {
    @Test("reads from the opened descriptor after the path is replaced")
    func readsFromOpenedDescriptorAfterPathReplacement() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "awesomux-secure-read-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

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
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
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
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
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
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "oversized.toml")
        _ = FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 1024 * 1024 * 1024)
        try handle.close()

        #expect(throws: SecureFileReadError.tooLarge) {
            _ = try SecureFileReader.read(at: file, maximumBytes: 256 * 1024)
        }
    }

    @Test("rejects a FIFO without blocking")
    func rejectsFIFOWithoutBlocking() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fifo = directory.appending(path: "pipe.md")
        try #require(mkfifo(fifo.path, 0o600) == 0)

        #expect(throws: SecureFileReadError.notRegularFile) {
            _ = try SecureFileReader.open(at: fifo)
        }
    }

    @Test("rejects a symlink to a device")
    func rejectsSymlinkToDevice() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let symlink = directory.appending(path: "device.md")
        try FileManager.default.createSymbolicLink(
            at: symlink,
            withDestinationURL: URL(fileURLWithPath: "/dev/null")
        )

        #expect(throws: SecureFileReadError.notRegularFile) {
            _ = try SecureFileReader.open(at: symlink)
        }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "awesomux-secure-read-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
