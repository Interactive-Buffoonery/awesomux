import Foundation
import Testing
@testable import AwesoMuxCore

@Suite("Git worktree porcelain parser")
struct GitWorktreePorcelainParserTests {
    private let parser = GitWorktreePorcelainParser()

    @Test("parses main, linked, and detached records using double-NUL record boundaries")
    func commonRecords() throws {
        let result = parser.parse(
            porcelain(
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

    @Test("parses locked and prunable markers with and without reasons")
    func administrativeMarkers() {
        let result = parser.parse(
            porcelain(
                ["worktree /one", "HEAD aaa", "branch refs/heads/main", "locked", "prunable"],
                ["worktree /two", "HEAD bbb", "branch refs/heads/two", "locked in use\nelsewhere", "prunable stale\tmetadata"]
            ))

        #expect(result.diagnostics.isEmpty)
        #expect(result.records[0].lockReason == "")
        #expect(result.records[0].prunableReason == "")
        #expect(result.records[1].lockReason == "in use\nelsewhere")
        #expect(result.records[1].prunableReason == "stale\tmetadata")
    }

    @Test("unknown fields are ignored and bare or unborn records may omit HEAD")
    func futureFieldsAndOptionalHead() {
        let result = parser.parse(
            porcelain(
                ["worktree /bare", "bare", "future-field value"],
                ["worktree /unborn", "branch refs/heads/new", "another-future-field"]
            ))

        #expect(result.diagnostics.isEmpty)
        #expect(result.records[0].isBare)
        #expect(result.records[0].headObjectID == nil)
        #expect(result.records[1].headObjectID == nil)
    }

    @Test("NUL framing preserves spaces, tabs, and newlines in worktree paths")
    func unusualPaths() {
        let path = "/repo/space here\ttab\nnewline"
        let result = parser.parse(
            porcelain(
                ["worktree \(path)", "HEAD aaa", "branch refs/heads/odd\tbranch\nname"]
            ))

        #expect(result.diagnostics.isEmpty)
        #expect(result.records[0].canonicalPath.path == path)
        #expect(result.records[0].displayBranch == "odd�branch�name")
    }

    @Test("empty output is an empty successful parse")
    func emptyOutput() {
        #expect(parser.parse(Data()) == GitWorktreeParseResult(records: [], diagnostics: []))
    }

    @Test("malformed records are omitted while later records still parse")
    func malformedRecordRecovery() {
        let result = parser.parse(
            porcelain(
                ["HEAD aaa", "branch refs/heads/missing-path"],
                ["worktree /valid", "HEAD bbb", "branch refs/heads/valid"]
            ))

        #expect(result.records.count == 1)
        #expect(result.records[0].canonicalPath.path == "/valid")
        #expect(result.diagnostics.count == 1)
        #expect(result.diagnostics[0].recordIndex == 0)
    }

    @Test("a record without the empty NUL terminator is diagnosed and omitted")
    func truncatedRecord() {
        let data = Data("worktree /repo\0HEAD aaa\0branch refs/heads/main\0".utf8)
        let result = parser.parse(data)
        #expect(result.records.isEmpty)
        #expect(result.diagnostics.count == 1)
    }

    @Test("invalid UTF-8 diagnoses only its containing record")
    func invalidUTF8() {
        var data = Data("worktree /bad\0HEAD ".utf8)
        data.append(contentsOf: [0xFF, 0, 0])
        data.append(porcelain(["worktree /good", "HEAD aaa", "detached"]))

        let result = parser.parse(data)
        #expect(result.diagnostics.count == 1)
        #expect(result.records.count == 1)
        #expect(result.records[0].canonicalPath.path == "/good")
    }

    private func porcelain(_ records: [String]...) -> Data {
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
