#!/usr/bin/env python3
"""Real Git + production PathInfo/watcher check; not a mounted native UI test."""
from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
model = (ROOT / 'Sources/awesoMux/Views/TerminalPathBarModel.swift').read_text()
path_info = 'struct PathInfo: Sendable {' + model.split('private struct PathInfo {', 1)[1]
view = (ROOT / 'Sources/awesoMux/Views/TerminalPathBarView.swift').read_text()
watch = '    func watchHead(' + view.split('    private func watchHead(', 1)[1].split('    private var resolveKey:', 1)[0]
watch = watch.replace('        watcher.start()', '        watcher.start()\n        WatcherProbe.latest = watcher')
ordinary_read = view.split('                let session = session\n', 1)[1].split('                // Advance the classifier', 1)[0]
ordinary_commit = '                let previousPullRequest' + view.split('                let previousPullRequest', 1)[1].split('                // A pane that became remote', 1)[0]
ordinary_commit = ordinary_commit.replace('                let revision = headRevision\n', '')
watch = watch.replace('}.value', '}.value\n                WatcherProbe.completions += 1')
chip_guard = view.split('                    for await lookup in group {', 1)[1].split('                        switch lookup', 1)[0].replace('else { break }', 'else { return false }')
path_info = path_info.replace('    let branch: String?', '    var branch: String?').replace('    let gitBranch: String?', '    var gitBranch: String?')
status_refresh = '    func refreshHeadGitStatus(' + view.split('    private func refreshHeadGitStatus(', 1)[1].split('    @MainActor\n    private func watchHead', 1)[0]
formatter = (ROOT / 'Sources/awesoMux/Views/TerminalAccessibilityPathFormatter.swift').read_text().replace('import AwesoMuxCore\n', '')
fixture = r'''
struct TerminalSession: Sendable { var workingDirectory: String; var role = "watcher" }
typealias TerminalPathBarModel = PathInfo
extension PathInfo {
    static func make(session: TerminalSession) -> PathInfo {
        let result = PathInfo(workingDirectory: session.workingDirectory, fallbackProject: "unchanged title", fileManager: .default, homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
        ReadGate.shared.holdIfRequested(role: session.role)
        return result
    }
}
final class ReadGate: @unchecked Sendable {
    static let shared = ReadGate()
    private let lock = NSLock()
    private var requested = false
    private var entered = false
    private var requestedRole = "watcher"
    let release = DispatchSemaphore(value: 0)
    func request(role: String = "watcher") { lock.lock(); requested = true; entered = false; requestedRole = role; lock.unlock() }
    var started: Bool { lock.lock(); defer { lock.unlock() }; return entered }
    func holdIfRequested(role: String) {
        lock.lock()
        let hold = requested && role == requestedRole
        if hold { requested = false }
        if hold { entered = true }
        lock.unlock()
        if hold { release.wait() }
    }
}
@MainActor enum WatcherProbe {
    static var latest: DocumentFileWatcher?
    static var completions = 0
    static var paused = false
    static var pending: [@MainActor () -> Void] = []
    static func deliver(_ callback: @escaping @MainActor () -> Void) {
        if paused { pending.append(callback) } else { callback() }
    }
    static func resume() {
        paused = false
        let callbacks = pending
        pending = []
        for callback in callbacks { callback() }
    }
}
extension DocumentFileWatcher { var fixtureIsArmed: Bool { source != nil } }
struct HeadStatusKey: Equatable { var url: URL?; var revision: UInt64; var owner: Int }
@MainActor enum StatusProbe {
    static var hold = false
    static var pending: CheckedContinuation<Void, Never>?
}
@MainActor struct GitStatusResolver {
    static let shared = GitStatusResolver()
    func status(repoRoot: String, branch: String) async -> String? {
        if StatusProbe.hold {
            await withCheckedContinuation { StatusProbe.pending = $0 }
        }
        return "status for " + branch
    }
}
@MainActor final class WatchFixture {
    var model: PathInfo
    var headRevision: UInt64 = 0
    var headReadRevision: UInt64 = 0
    var hasResolved = true
    var owner = 0
    var headStatusKey: HeadStatusKey { HeadStatusKey(url: headWatchURL, revision: headRevision, owner: owner) }
    var headWatchURL: URL? { model.gitHeadURL }
    init(_ model: PathInfo) { self.model = model }
    func resolveOrdinarily(session: TerminalSession) async {
ORDINARY_READ
ORDINARY_COMMIT
    }
    func acceptsChip(revision: UInt64, repoRoot: String, resolved: PathInfo) -> Bool {
CHIP_GUARD
        return true
    }
STATUS_REFRESH
WATCH
}
@MainActor func wait(_ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition() && ContinuousClock.now < deadline { await Task.yield() }
    precondition(condition(), "bounded event wait expired")
}

enum WorkingDirectoryValidator {
    static let canonicalHomeDirectory = FileManager.default.homeDirectoryForCurrentUser.path
}
func git(_ root: String, _ args: [String]) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    p.arguments = ["-C", root, "-c", "core.hooksPath=/dev/null"] + args
    try p.run()
    p.waitUntilExit()
    precondition(p.terminationStatus == 0)
}
@main struct Check {
    @MainActor static func main() async throws {
        let root = CommandLine.arguments[1]
        try git(root, ["init", "-q", "-b", "old"])
        try git(root, ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty", "-qm", "fixture", "--no-gpg-sign"])
        try git(root, ["branch", "next"])
        func resolve(_ path: String) -> PathInfo {
            PathInfo(workingDirectory: path, fallbackProject: "unchanged title", fileManager: .default, homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
        }
        let worktree = root + "-worktree"
        try git(root, ["worktree", "add", "-q", "-b", "work", worktree])
        // A relative .git pointer still resolves to the worktree's own HEAD.
        let marker = URL(fileURLWithPath: worktree).appendingPathComponent(".git")
        let absoluteAdmin = resolve(worktree).gitHeadURL!.deletingLastPathComponent().path
        let relativeAdmin = "../" + URL(fileURLWithPath: root).lastPathComponent + "/.git/worktrees/" + URL(fileURLWithPath: absoluteAdmin).lastPathComponent
        try ("gitdir: " + relativeAdmin + "\n").write(to: marker, atomically: true, encoding: .utf8)
        precondition(resolve(worktree).gitHeadURL != resolve(root).gitHeadURL)
        // Hold the production watcher's initial detached read across a real checkout.
        let heldOwner = WatchFixture(resolve(root))
        ReadGate.shared.request()
        let heldTask = Task { await heldOwner.watchHead(url: heldOwner.model.gitHeadURL!, session: TerminalSession(workingDirectory: root)) }
        await wait { ReadGate.shared.started }
        var heldEvents = 0
        let heldProbe = DocumentFileWatcher(url: heldOwner.model.gitHeadURL!) { heldEvents += 1 }
        heldProbe.start()
        try git(root, ["checkout", "-q", "next"])
        await wait { heldEvents > 0 }
        heldProbe.stop()
        ReadGate.shared.release.signal()
        await wait { heldOwner.model.gitBranch == "next" }
        heldTask.cancel()
        await heldTask.value
        print("PASS: held stale watcher read discarded, buffered HEAD event reconciled")
        let movedOwner = WatchFixture(resolve(root))
        ReadGate.shared.request()
        let movedTask = Task { await movedOwner.watchHead(url: movedOwner.model.gitHeadURL!, session: TerminalSession(workingDirectory: root)) }
        await wait { ReadGate.shared.started }
        movedOwner.model = resolve(worktree)
        let movedBranch = movedOwner.model.gitBranch
        let cancelledWatcher = WatcherProbe.latest!
        // Cancel before releasing the detached read, then change old HEAD.
        movedTask.cancel()
        let cancelledRevision = movedOwner.headRevision
        let control = WatchFixture(resolve(root))
        let controlTask = Task { await control.watchHead(url: control.model.gitHeadURL!, session: TerminalSession(workingDirectory: root)) }
        await Task.yield()
        try git(root, ["checkout", "-q", "--detach"])
        await wait { control.headRevision > 0 && control.model.gitBranch == nil }
        let controlRevision = control.headRevision
        try git(root, ["checkout", "-q", "next"])
        await wait { control.headRevision > controlRevision && control.model.gitBranch == "next" }
        precondition(!cancelledWatcher.fixtureIsArmed, "cancelled watcher kept source armed during held read")
        precondition(movedOwner.headRevision == cancelledRevision, "cancelled old-repo callback invalidated new state")
        controlTask.cancel()
        await controlTask.value
        ReadGate.shared.release.signal()
        await movedTask.value
        precondition(movedOwner.model.gitBranch == movedBranch && movedOwner.model.copyPath == resolve(worktree).copyPath)
        print("PASS: repo transition/cancellation rejects outstanding old-repo read")
        // Reverse completion order, with native event delivery held explicitly.
        let reverseOwner = WatchFixture(resolve(root))
        ReadGate.shared.request()
        let reverseTask = Task { await reverseOwner.watchHead(url: reverseOwner.model.gitHeadURL!, session: TerminalSession(workingDirectory: root)) }
        await wait { ReadGate.shared.started }
        WatcherProbe.paused = true
        try git(root, ["checkout", "-q", "old"])
        await reverseOwner.resolveOrdinarily(session: TerminalSession(workingDirectory: root, role: "ordinary"))
        precondition(reverseOwner.model.gitBranch == "old")
        let completions = WatcherProbe.completions
        ReadGate.shared.release.signal()
        await wait { WatcherProbe.completions > completions }
        precondition(reverseOwner.model.gitBranch == "old", "older watcher read overwrote newer ordinary commit")
        reverseTask.cancel()
        await reverseTask.value
        WatcherProbe.resume()
        print("PASS: older watcher completion cannot overwrite newer ordinary commit")
        try git(root, ["checkout", "-q", "next"])
        let abaOwner = WatchFixture(resolve(root))
        let abaInitialCompletions = WatcherProbe.completions
        let abaTask = Task { await abaOwner.watchHead(url: abaOwner.model.gitHeadURL!, session: TerminalSession(workingDirectory: root)) }
        await wait { WatcherProbe.completions > abaInitialCompletions }
        try git(root, ["checkout", "-q", "old"])
        ReadGate.shared.request(role: "ordinary")
        let ordinaryTask = Task { await abaOwner.resolveOrdinarily(session: TerminalSession(workingDirectory: root, role: "ordinary")) }
        await wait { ReadGate.shared.started }
        let abaReadCompletions = WatcherProbe.completions
        try git(root, ["checkout", "-q", "next"])
        await wait { WatcherProbe.completions > abaReadCompletions }
        ReadGate.shared.release.signal()
        await ordinaryTask.value
        precondition(abaOwner.model.gitBranch == "next", "held ordinary ABA read overwrote final watcher reconciliation")
        abaTask.cancel()
        await abaTask.value
        print("PASS: held ordinary ABA read retries after final watcher reconciliation")
        // Exercise the production chip-completion guard across identical HEAD rewrites.
        let sameOwner = WatchFixture(resolve(root))
        let sameSnapshot = sameOwner.model
        let sameRevision = sameOwner.headRevision
        let sameTask = Task { await sameOwner.watchHead(url: sameSnapshot.gitHeadURL!, session: TerminalSession(workingDirectory: root)) }
        await Task.yield()
        var observed = 0
        let probe = DocumentFileWatcher(url: sameSnapshot.gitHeadURL!) { observed += 1 }
        probe.start()
        for index in 1...2 {
            try git(root, ["symbolic-ref", "HEAD", "refs/heads/next"])
            await wait { observed >= index }
        }
        precondition(sameOwner.acceptsChip(revision: sameRevision, repoRoot: sameSnapshot.repoRootPath!, resolved: sameSnapshot), "identical HEAD rewrite discarded valid held chip completion")
        sameTask.cancel()
        await sameTask.value
        probe.stop()
        print("PASS: identical HEAD rewrites retain valid held chip completions")
        let refillOwner = WatchFixture(resolve(root))
        let refillTask = Task { await refillOwner.watchHead(url: refillOwner.model.gitHeadURL!, session: TerminalSession(workingDirectory: root)) }
        try git(root, ["checkout", "-q", "old"])
        await wait { refillOwner.model.gitBranch == "old" }
        await refillOwner.refreshHeadGitStatus(key: refillOwner.headStatusKey)
        precondition(refillOwner.model.gitStatus == "status for old", "watched branch did not refill local status")
        precondition(refillOwner.model.pullRequest == nil && refillOwner.model.ciStatus == nil, "watch refresh must not start remote chip lookups")
        StatusProbe.hold = true
        let staleStatus = Task { await refillOwner.refreshHeadGitStatus(key: refillOwner.headStatusKey) }
        await wait { StatusProbe.pending != nil }
        try git(root, ["checkout", "-q", "next"])
        await wait { refillOwner.model.gitBranch == "next" }
        refillOwner.owner += 1
        refillOwner.model.gitStatus = "new owner"
        StatusProbe.hold = false
        StatusProbe.pending?.resume()
        StatusProbe.pending = nil
        await staleStatus.value
        precondition(refillOwner.model.gitStatus == "new owner", "old presentation status overwrote new owner")
        refillTask.cancel()
        await refillTask.value
        print("PASS: local status refill, slow-status watch progress, stale owner rejection; no remote lookups")
        for path in [root, worktree] {
            let initial = resolve(path)
            let owner = WatchFixture(initial)
            let task = Task { await owner.watchHead(url: initial.gitHeadURL!, session: TerminalSession(workingDirectory: path)) }
            await Task.yield()
            try git(path, ["checkout", "-q", "--detach"])
            await wait { owner.model.gitBranch == nil && owner.model.branch != initial.branch }
            try git(path, ["checkout", "-q", path == root ? "next" : "work"])
            await wait { owner.model.gitBranch == (path == root ? "next" : "work") }
            // Git checkout replaces HEAD atomically. A second replacement proves re-arming.
            try git(path, ["checkout", "-q", "--detach"])
            await wait { owner.model.gitBranch == nil }
            precondition(owner.model.copyPath == initial.copyPath)
            precondition(owner.model.pullRequest == nil && owner.model.gitStatus == nil && owner.model.ciStatus == nil)
            task.cancel()
            await task.value
            let stopped = owner.model.branch
            try git(path, ["checkout", "-q", path == root ? "next" : "work"])
            // An independent vnode event gives cancelled sources time to misfire.
            let control = WatchFixture(resolve(path))
            let controlTask = Task { await control.watchHead(url: control.model.gitHeadURL!, session: TerminalSession(workingDirectory: path)) }
            await Task.yield()
            try git(path, ["checkout", "-q", "--detach"])
            await wait { control.model.gitBranch == nil }
            precondition(owner.model.branch == stopped, "cancelled watch changed model")
            controlTask.cancel()
            await controlTask.value
            print("PASS: unchanged title/cwd checkout, detached HEAD, repeated replacement, cancellation: \(path)")
        }
    }
}
'''
fixture = fixture.replace('STATUS_REFRESH', status_refresh).replace('WATCH', watch).replace('CHIP_GUARD', chip_guard).replace('ORDINARY_READ', ordinary_read).replace('ORDINARY_COMMIT', ordinary_commit)
# Only view @State storage is replaced. PathInfo and watchHead execute production source.
path_info = path_info.replace('    let project: String', '    var pullRequest: String? = "old PR"\n    var gitStatus: String? = "old status"\n    var ciStatus: String? = "old CI"\n    let project: String', 1)
source = '\n'.join(['import Foundation', path_info, formatter,
    (ROOT / 'Sources/awesoMux/Services/GitRepoRootLocator.swift').read_text(),
    (ROOT / 'Sources/awesoMux/Services/DocumentFileWatcher.swift').read_text().replace('self.onChange()', 'WatcherProbe.deliver(self.onChange)').replace('            onChange()', '            WatcherProbe.deliver(onChange)'), fixture])
with tempfile.TemporaryDirectory(prefix='awesomux-head-watch-') as directory:
    temp = Path(directory)
    (temp / 'check.swift').write_text(source)
    env = {k: v for k, v in os.environ.items() if not k.startswith('GIT_')}
    (temp / 'templates').mkdir()
    env.update(GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null', GIT_TEMPLATE_DIR=str(temp / 'templates'))
    subprocess.run(['swiftc', '-swift-version', '6', '-parse-as-library', str(temp / 'check.swift'), '-o', str(temp / 'check')], check=True, env=env)
    (temp / 'repo').mkdir()
    subprocess.run([str(temp / 'check'), str(temp / 'repo')], check=True, env=env, timeout=15)
