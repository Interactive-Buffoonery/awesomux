import Foundation
import Testing
@testable import AwesoMuxCore

@Suite struct MarkdownFileEnumeratorTests {
    @Test func enumeratesMarkdownFilesOnly() throws {
        try withTemporaryDirectory { root in
            try writeFile("root", at: root.appendingPathComponent("README.md"))
            try writeFile("draft", at: root.appendingPathComponent("draft.markdown"))
            try writeFile("notes", at: root.appendingPathComponent("notes.txt"))
            try writeFile("nested", at: root.appendingPathComponent("docs/plan.md"))

            let paths = Set(MarkdownFileEnumerator.enumerate(root: root).map(\.relativePath))

            #expect(paths == ["README.md", "draft.markdown", "docs/plan.md"])
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

    @Test func respectsDepthCap() throws {
        try withTemporaryDirectory { root in
            try writeFile("root", at: root.appendingPathComponent("root.md"))
            try writeFile("one", at: root.appendingPathComponent("one/one.md"))
            try writeFile("two", at: root.appendingPathComponent("one/two/two.md"))

            let entries = MarkdownFileEnumerator.enumerate(
                root: root,
                options: .init(maxDepth: 1)
            )
            let paths = Set(entries.map(\.relativePath))

            #expect(paths == ["root.md", "one/one.md"])
        }
    }

    @Test func respectsCountCap() throws {
        try withTemporaryDirectory { root in
            for index in 0..<5 {
                try writeFile("file \(index)", at: root.appendingPathComponent("file-\(index).md"))
            }

            let entries = MarkdownFileEnumerator.enumerate(
                root: root,
                options: .init(maxCount: 3)
            )

            #expect(entries.count == 3)
        }
    }

    /// The browser marks over-cap rows off `fileSizeBytes`, so the walk has to
    /// carry the size it already stats for. Without it every entry looks
    /// openable and the user only learns otherwise after the click has already
    /// replaced their tab.
    @Test func reportsFileSizeAndFlagsEntriesOverTheViewerCap() throws {
        try withTemporaryDirectory { root in
            let small = root.appendingPathComponent("small.md")
            try writeFile("tiny", at: small)
            let big = root.appendingPathComponent("big.md")
            try writeFile("", at: big)
            let handle = try FileHandle(forWritingTo: big)
            defer { try? handle.close() }
            // Sparse: the cap is a size check, so no bytes need to exist.
            try handle.truncate(atOffset: UInt64(DocumentURLValidator.maxFileSizeBytes + 1))
            try handle.close()

            let entries = MarkdownFileEnumerator.enumerate(root: root)
            let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.fileName, $0) })

            #expect(byName["small.md"]?.fileSizeBytes == 4)
            #expect(byName["small.md"]?.exceedsSizeCap == false)
            #expect(byName["big.md"]?.fileSizeBytes == DocumentURLValidator.maxFileSizeBytes + 1)
            #expect(byName["big.md"]?.exceedsSizeCap == true)
        }
    }

    /// A file exactly at the cap opens, so it must not be marked.
    @Test func doesNotFlagAFileExactlyAtTheCap() throws {
        try withTemporaryDirectory { root in
            let atCap = root.appendingPathComponent("at-cap.md")
            try writeFile("", at: atCap)
            let handle = try FileHandle(forWritingTo: atCap)
            try handle.truncate(atOffset: UInt64(DocumentURLValidator.maxFileSizeBytes))
            try handle.close()

            let entry = try #require(MarkdownFileEnumerator.enumerate(root: root).first)

            #expect(entry.fileSizeBytes == DocumentURLValidator.maxFileSizeBytes)
            #expect(entry.exceedsSizeCap == false)
        }
    }

    @Test func nonDirectoryRootReturnsEmptyList() throws {
        try withTemporaryDirectory { root in
            let file = root.appendingPathComponent("README.md")
            try writeFile("root", at: file)

            #expect(MarkdownFileEnumerator.enumerate(root: file).isEmpty)
        }
    }
}

@Suite struct MarkdownFileSearchTests {
    @Test func emptyQueryKeepsEnumeratorOrder() {
        let entries = [
            entry("README.md"),
            entry("docs/Architecture.md"),
        ]

        let hits = MarkdownFileSearch.hits(in: entries, query: "")

        #expect(hits.map(\.entry.relativePath) == ["README.md", "docs/Architecture.md"])
        #expect(hits.map(\.score) == [0, 0])
    }

    @Test func queryUsesFuzzyMatcherAndSortsByScore() {
        let entries = [
            entry("archive/axpxi-notes.md"),
            entry("docs/API.md"),
            entry("docs/roadmap.md"),
        ]

        let hits = MarkdownFileSearch.hits(in: entries, query: "api")

        #expect(hits.map(\.entry.relativePath) == ["docs/API.md", "archive/axpxi-notes.md"])
        #expect(hits[0].score > hits[1].score)
    }

    @Test func equalScoresPreferShorterRelativePath() {
        let entries = [
            entry("archive/api-notes.md"),
            entry("docs/API.md"),
        ]

        let hits = MarkdownFileSearch.hits(in: entries, query: "api")

        #expect(hits.map(\.entry.relativePath) == ["docs/API.md", "archive/api-notes.md"])
        #expect(hits[0].score == hits[1].score)
    }
}

@Suite struct MarkdownDirectoryBrowserTests {
    @Test func rootContentsGroupMarkdownFilesByImmediateDirectory() {
        let entries = [
            entry("README.md"),
            entry("docs/Architecture.md"),
            entry("docs/adr/0001.md"),
            entry("notes/daily.md"),
        ]

        let contents = MarkdownDirectoryBrowser.contents(in: entries, at: "")

        #expect(contents.parentRelativePath == nil)
        #expect(contents.directories.map(\.relativePath) == ["docs", "notes"])
        #expect(contents.files.map(\.relativePath) == ["README.md"])
    }

    @Test func nestedContentsShowChildDirectoriesAndDirectFiles() {
        let entries = [
            entry("docs/Architecture.md"),
            entry("docs/adr/0001.md"),
            entry("docs/adr/0002.md"),
            entry("docs/examples/handoff.md"),
        ]

        let contents = MarkdownDirectoryBrowser.contents(in: entries, at: "docs")

        #expect(contents.parentRelativePath == "")
        #expect(contents.directories.map(\.relativePath) == ["docs/adr", "docs/examples"])
        #expect(contents.files.map(\.relativePath) == ["docs/Architecture.md"])
    }

    @Test func breadcrumbsBuildAncestorPaths() {
        let breadcrumbs = MarkdownDirectoryBrowser.breadcrumbs(for: "docs/adr/current")

        #expect(breadcrumbs.map(\.name) == ["docs", "adr", "current"])
        #expect(breadcrumbs.map(\.relativePath) == ["docs", "docs/adr", "docs/adr/current"])
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

private func entry(_ relativePath: String) -> MarkdownFileEntry {
    let url = URL(fileURLWithPath: "/tmp/project").appendingPathComponent(relativePath)
    return MarkdownFileEntry(url: url, relativePath: relativePath)
}
