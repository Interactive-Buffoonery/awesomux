#!/usr/bin/env python3
"""Exercise the production menu method with held enumeration and real Git HEAD changes.

This is a source-extracted integration check, not a hosted SwiftUI/native UI test.
Only surrounding view storage and the async runner are replaced. PathInfo, menu
filtering, loading ownership, and toggleBranchMenu execute from current source.
"""
from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def read(path):
    return (ROOT / path).read_text()


view = read("Sources/awesoMux/Views/TerminalPathBarView.swift")
method = view.split("    @MainActor\n    private func toggleBranchMenu() {", 1)[1]
method = "    func toggleBranchMenu() {" + method.split("\n    private func appIcon", 1)[0]
model = read("Sources/awesoMux/Views/TerminalPathBarModel.swift")
path_info = "private struct PathInfo {" + model.split("private struct PathInfo {", 1)[1]
branch_list = read("Sources/awesoMux/Views/TerminalPathBarBranchList.swift")
loading = branch_list.split("// MARK: - Command runner", 1)[0]
menu = "enum BranchListMenuModel {" + branch_list.split("enum BranchListMenuModel {", 1)[1].split("// MARK: - Resolver", 1)[0]
formatter = read("Sources/awesoMux/Views/TerminalAccessibilityPathFormatter.swift").replace("import AwesoMuxCore\n", "")
fixture = r'''
enum WorkingDirectoryValidator {
    static let canonicalHomeDirectory = FileManager.default.homeDirectoryForCurrentUser.path
}
@MainActor
final class BranchListResolver {
    static let shared = BranchListResolver()
    var started = false
    var pending: CheckedContinuation<[String]?, Never>?
    func branches(repoRoot: String) async -> [String]? {
        started = true
        return await withCheckedContinuation { pending = $0 }
    }
}
enum PathBarMenu { case branches }
@MainActor
final class MenuFixture {
    // Reference storage stands in for mounted @State. The method below is verbatim.
    var model: PathInfo
    var presentedMenu: PathBarMenu?
    var branchMenuLoad = BranchMenuLoadState()
    var currentBranchForMenu: String?
    var branchesForMenu: [String]?
    init(_ model: PathInfo) { self.model = model }
METHOD
}
@discardableResult
func git(_ root: String, _ args: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", root, "-c", "core.hooksPath=/dev/null"] + args
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    precondition(process.terminationStatus == 0)
    return String(decoding: data, as: UTF8.self)
}
@main struct Check {
    @MainActor static func main() async throws {
        let root = CommandLine.arguments[1]
        let old = CommandLine.arguments[2]
        try git(root, ["init", "-q", "-b", old])
        try git(root, ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                       "commit", "--allow-empty", "-qm", "fixture", "--no-gpg-sign"])
        try git(root, ["branch", "next"])
        func resolve() -> PathInfo {
            PathInfo(workingDirectory: root, fallbackProject: "fixture",
                     fileManager: .default, homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
        }
        let initial = resolve()
        precondition(initial.gitBranch == old && initial.branch == "oldbranch")
        let fixture = MenuFixture(initial)
        fixture.toggleBranchMenu()
        precondition(fixture.branchMenuLoad.isLoading)
        // A bounded yield loop waits for the held runner, not a timing-dependent sleep.
        for _ in 0..<10000 {
            if BranchListResolver.shared.started { break }
            await Task.yield()
        }
        precondition(BranchListResolver.shared.started, "enumeration did not start")
        fixture.toggleBranchMenu()
        try git(root, ["checkout", "-q", "next"])
        fixture.model = resolve()
        precondition(fixture.model.gitBranch == "next" && fixture.model.branch == "next")
        precondition(fixture.model.copyPath == initial.copyPath)
        let rows = try git(root, ["for-each-ref", "refs/heads", "--format=%(refname:short)"])
            .split(separator: "\n").map(String.init)
        BranchListResolver.shared.pending!.resume(returning: rows)
        for _ in 0..<10000 {
            if !fixture.branchMenuLoad.isLoading { break }
            await Task.yield()
        }
        precondition(!fixture.branchMenuLoad.isLoading && fixture.presentedMenu == .branches)
        print("HEAD/model: next; pinned: \(fixture.currentBranchForMenu ?? "nil"); rows: \(fixture.branchesForMenu ?? [])")
        precondition(fixture.currentBranchForMenu == initial.branch, "pinned label crossed snapshots")
        precondition(fixture.branchesForMenu == ["next"], "raw filtering or checkout safety changed")
        precondition(BranchListMenuModel.checkoutCommand(branch: "next") == "git checkout 'next'")
        print("PASS: one open-time raw/display snapshot survives real HEAD/model refresh")
    }
}
'''.replace("METHOD", method)
# PathInfo is private in its original file; the fixture shares that file's scope.
source = "\n".join([loading, path_info, menu, formatter,
                     read("Sources/awesoMux/Services/GitRepoRootLocator.swift"), fixture])
source = source.replace("private struct PathInfo", "struct PathInfo")
with tempfile.TemporaryDirectory(prefix="awesomux-branch-snapshot-") as temporary:
    temp = Path(temporary)
    (temp / "check.swift").write_text(source)
    # Git must not inherit repository routing, config, hooks or templates.
    environment = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    (temp / "templates").mkdir()
    environment.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL="/dev/null",
                       GIT_TEMPLATE_DIR=str(temp / "templates"))
    subprocess.run(["swiftc", "-parse-as-library", str(temp / "check.swift"), "-o", str(temp / "check")], check=True, env=environment)
    for index, branch in enumerate(["oldbranch", "old\u202ebranch"]):
        repository = temp / f"repo-{index}"
        repository.mkdir()
        subprocess.run([str(temp / "check"), str(repository), branch], check=True, env=environment)
