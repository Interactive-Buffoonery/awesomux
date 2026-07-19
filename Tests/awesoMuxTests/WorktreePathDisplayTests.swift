import Testing
@testable import awesoMux

@Suite("Worktree path display")
struct WorktreePathDisplayTests {
    @Test("short paths pass through unchanged")
    func shortPathUnchanged() {
        #expect(WorktreePathDisplay.condensed("/tmp/repo") == "/tmp/repo")
    }

    @Test("long paths condense to the trailing components, leaf fully intact")
    func longPathKeepsLeaf() {
        let path = "/Users/devuser/Development/awesomux/.worktrees/int-857-worktree-manager"
        #expect(WorktreePathDisplay.condensed(path) == "…/.worktrees/int-857-worktree-manager")
    }
}
