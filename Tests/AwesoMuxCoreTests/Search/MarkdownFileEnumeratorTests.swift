import Foundation
import Testing
@testable import AwesoMuxCore

@Suite("MarkdownFileEnumerator")
struct MarkdownFileEnumeratorTests {
    @Test(arguments: [false, true])
    func enumerationCaps(countCap: Bool) throws {
        try withTemporaryDirectory { root in
            if countCap {
                for index in 0..<5 { try writeFile("file \(index)", at: root.appendingPathComponent("file-\(index).md")) }
                #expect(MarkdownFileEnumerator.enumerate(root: root, options: .init(maxCount: 3)).count == 3)
            } else {
                try writeFile("root", at: root.appendingPathComponent("root.md"))
                try writeFile("one", at: root.appendingPathComponent("one/one.md"))
                try writeFile("two", at: root.appendingPathComponent("one/two/two.md"))
                let entries = MarkdownFileEnumerator.enumerate(root: root, options: .init(maxDepth: 1))
                #expect(Set(entries.map(\.relativePath)) == ["root.md", "one/one.md"])
            }
        }
    }

    @Test(arguments: [0, 1])
    func fileSizeFlags(extraBytes: Int) throws {
        try withTemporaryDirectory { root in
            try writeFile("tiny", at: root.appendingPathComponent("small.md"))
            let file = root.appendingPathComponent("at-cap.md")
            try writeFile("", at: file)
            let handle = try FileHandle(forWritingTo: file)
            try handle.truncate(atOffset: UInt64(DocumentURLValidator.maxFileSizeBytes + extraBytes))
            try handle.close()
            let entries = MarkdownFileEnumerator.enumerate(root: root)
            let entry = try #require(entries.first { $0.fileName == "at-cap.md" })
            #expect(entry.fileSizeBytes == DocumentURLValidator.maxFileSizeBytes + extraBytes)
            #expect(entry.exceedsSizeCap == (extraBytes > 0))
            let small = try #require(entries.first { $0.fileName == "small.md" })
            #expect(small.fileSizeBytes == 4)
            #expect(!small.exceedsSizeCap)
        }
    }

    @Test func skipsGeneratedAndDependencyDirectories() throws {
        try withTemporaryDirectory { root in
            try writeFile("ok", at: root.appendingPathComponent("docs/plan.md"))
            try writeFile("git", at: root.appendingPathComponent(".git/COMMIT_EDITMSG.md"))
            try writeFile("node", at: root.appendingPathComponent("node_modules/pkg/readme.md"))
            try writeFile("vendor", at: root.appendingPathComponent("vendor/lib/readme.md"))
            try writeFile("build", at: root.appendingPathComponent(".build/checkouts/pkg/readme.md"))
            try writeFile("swiftpm", at: root.appendingPathComponent(".swiftpm/xcode/readme.md"))
            try writeFile("worktree", at: root.appendingPathComponent(".worktrees/branch/readme.md"))

            let paths = MarkdownFileEnumerator.enumerate(root: root).map(\.relativePath)

            #expect(paths == ["docs/plan.md"])
        }
    }
}

private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("awesomux-markdown-files-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: root)
    }
    try body(root)
}

private func writeFile(_ contents: String, at url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try contents.write(to: url, atomically: true, encoding: .utf8)
}
