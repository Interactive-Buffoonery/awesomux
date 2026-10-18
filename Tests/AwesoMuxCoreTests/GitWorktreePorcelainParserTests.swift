import Foundation
import Testing
@testable import AwesoMuxCore

@Suite("Git worktree porcelain parser")
struct GitWorktreePorcelainParserTests {
    private let parser = GitWorktreePorcelainParser()

    private static var malformedCases: [(Data, [String], Int)] {
        var invalidUTF8 = Data("worktree /bad\0HEAD ".utf8)
        invalidUTF8.append(contentsOf: [0xFF, 0, 0])
        invalidUTF8.append(porcelain(["worktree /good", "HEAD aaa", "detached"]))
        return [
            (
                porcelain(["HEAD aaa", "branch refs/heads/missing-path"], ["worktree /valid", "HEAD bbb", "branch refs/heads/valid"]),
                ["/valid"], 1
            ),
            (Data("worktree /repo\0HEAD aaa\0branch refs/heads/main\0".utf8), [], 1),
            (invalidUTF8, ["/good"], 1),
        ]
    }

    @Test(arguments: Self.malformedCases)
    func malformedInput(data: Data, expectedPaths: [String], diagnosticCount: Int) {
        let result = parser.parse(data)
        #expect(result.records.map { $0.canonicalPath.path } == expectedPaths)
        #expect(result.diagnostics.count == diagnosticCount)
        #expect(result.diagnostics.first?.recordIndex == 0)
    }

    @Test("parses main, linked, and detached records using double-NUL record boundaries")
    func commonRecords() throws {
        let result = parser.parse(
            Self.porcelain(
                ["worktree /repo", "HEAD aaa", "branch refs/heads/main"],
                ["worktree /repo/feature", "HEAD bbb", "branch refs/heads/feature/foo"],
                ["worktree /repo/detached", "HEAD ccc", "detached"]
            ))

        #expect(result.diagnostics.isEmpty)
        #expect(result.records.count == 3)
        #expect(result.records[0].isMainWorktree)
        #expect(!result.records[1].isMainWorktree)
        #expect(result.records[1].branchRef == "refs/heads/feature/foo")
        #expect(result.records[1].displayBranch == "feature/foo")
        #expect(result.records[2].isDetached)
        #expect(result.records[2].displayBranch == "detached HEAD")
    }

    @Test("NUL framing preserves spaces, tabs, and newlines in worktree paths")
    func unusualPaths() {
        let path = "/repo/space here\ttab\nnewline"
        let result = parser.parse(
            Self.porcelain(
                ["worktree \(path)", "HEAD aaa", "branch refs/heads/odd\tbranch\nname"]
            ))

        #expect(result.diagnostics.isEmpty)
        #expect(result.records[0].canonicalPath.path == path)
        #expect(result.records[0].displayBranch == "odd�branch�name")
    }

    private static func porcelain(_ records: [String]...) -> Data {
        var data = Data()
        for record in records {
            for field in record {
                data.append(Data(field.utf8))
                data.append(0)
            }
            data.append(0)
        }
        return data
    }
}
