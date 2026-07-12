import Foundation
import Testing
@testable import awesoMux

// MARK: - Parsing

@Suite("Branch list parsing")
struct BranchListParsingTests {
    // Trailing newline matches real `for-each-ref` output — a complete run
    // always ends the last ref line with `\n`; see `truncatedLineDropped`
    // below for what happens when it doesn't.
    private func lines(_ items: String...) -> Data {
        Data((items.joined(separator: "\n") + "\n").utf8)
    }

    @Test("branches parse one per line, order preserved")
    func ordering() {
        let branches = BranchListMenuModel.parse(lines("feature/int-773", "main", "fix/tiny"))
        #expect(branches == ["feature/int-773", "main", "fix/tiny"])
    }

    @Test("empty lines and trailing newline are dropped")
    func empties() {
        let branches = BranchListMenuModel.parse(Data("main\n\nfeature/x\n".utf8))
        #expect(branches == ["main", "feature/x"])
    }

    @Test("empty output parses to an empty list")
    func empty() {
        #expect(BranchListMenuModel.parse(Data()) == [])
    }

    @Test("data without a trailing newline drops the last (truncated) line")
    func truncatedLineDropped() {
        // BoundedCommandRunner's 512 KB cap can slice mid-line; a missing
        // trailing newline is the signal that the last entry is a fragment.
        let branches = BranchListMenuModel.parse(Data("main\nfeature/x\nfeature/y".utf8))
        #expect(branches == ["main", "feature/x"])
    }

    @Test("data with a trailing newline keeps every line")
    func trailingNewlineKeepsAll() {
        let branches = BranchListMenuModel.parse(Data("main\nfeature/x\nfeature/y\n".utf8))
        #expect(branches == ["main", "feature/x", "feature/y"])
    }
}

// MARK: - Menu model

@Suite("Branch list menu model")
struct BranchListMenuModelTests {
    @Test("current branch is removed from the clickable rows")
    func currentRemoved() {
        let others = BranchListMenuModel.otherBranches(
            branches: ["feature/a", "main", "feature/b"],
            currentBranch: "main"
        )
        #expect(others == ["feature/a", "feature/b"])
    }

    @Test("nil current branch leaves the list untouched")
    func nilCurrent() {
        let others = BranchListMenuModel.otherBranches(
            branches: ["main", "feature/a"],
            currentBranch: nil
        )
        #expect(others == ["main", "feature/a"])
    }

    @Test("option-shaped (leading-dash) branch names are excluded")
    func dashExcluded() {
        let others = BranchListMenuModel.otherBranches(
            branches: ["-f", "main", "--force", "feature/a"],
            currentBranch: "main"
        )
        #expect(others == ["feature/a"])
    }

    @Test("a branch name containing a bidi override scalar is excluded")
    func bidiOverrideExcluded() {
        let others = BranchListMenuModel.otherBranches(
            branches: ["feature/a", "main", "feature/\u{202E}evil"],
            currentBranch: "main"
        )
        #expect(others == ["feature/a"])
    }

    @Test("checkout command single-quotes the branch")
    func quoting() {
        #expect(BranchListMenuModel.checkoutCommand(branch: "feature/int-773")
            == "git checkout 'feature/int-773'")
    }

    @Test("embedded single quote is escaped")
    func quoteEscape() {
        #expect(BranchListMenuModel.checkoutCommand(branch: "fix/it's")
            == "git checkout 'fix/it'\\''s'")
    }

    @Test("under the visible cap, every branch is visible with zero overflow")
    func visibleRowsUnderCap() {
        let branches = ["a", "b", "c"]
        let (visible, overflow) = BranchListMenuModel.visibleRows(branches)
        #expect(visible == branches)
        #expect(overflow == 0)
    }

    @Test("over the visible cap, the first cap-many stay and the rest count as overflow")
    func visibleRowsOverCap() {
        let branches = (0..<143).map { "branch-\($0)" }
        let (visible, overflow) = BranchListMenuModel.visibleRows(branches)
        #expect(visible.count == BranchListMenuModel.maxVisibleRows)
        #expect(visible == Array(branches.prefix(BranchListMenuModel.maxVisibleRows)))
        #expect(overflow == 143 - BranchListMenuModel.maxVisibleRows)
    }

    @Test("exactly at the cap, everything is visible with zero overflow")
    func visibleRowsAtCap() {
        let branches = (0..<BranchListMenuModel.maxVisibleRows).map { "branch-\($0)" }
        let (visible, overflow) = BranchListMenuModel.visibleRows(branches)
        #expect(visible == branches)
        #expect(overflow == 0)
    }
}

// MARK: - Resolver caching

@Suite("Branch list resolver")
struct BranchListResolverTests {
    private actor RecordingRunner {
        private(set) var callCount = 0
        private let response: Data?
        init(response: Data?) { self.response = response }
        func run() async -> Data? {
            callCount += 1
            return response
        }
        func count() -> Int { callCount }
    }

    @Test("second lookup within the TTL is served from cache")
    func cached() async {
        // Trailing newline: matches real `for-each-ref` output, so this
        // fixture isn't mistaken for a truncated read by `parse`'s new
        // dropped-final-line guard (see `BranchListParsingTests`).
        let runner = RecordingRunner(response: Data("main\nfeature/x\n".utf8))
        let resolver = BranchListResolver(runner: { _ in await runner.run() })
        let first = await resolver.branches(repoRoot: "/repo")
        let second = await resolver.branches(repoRoot: "/repo")
        #expect(first == ["main", "feature/x"])
        #expect(second == ["main", "feature/x"])
        #expect(await runner.count() == 1)
    }

    @Test("runner failure resolves to nil")
    func failure() async {
        let resolver = BranchListResolver(runner: { _ in nil })
        #expect(await resolver.branches(repoRoot: "/repo") == nil)
    }
}
