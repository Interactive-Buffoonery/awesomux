#!/usr/bin/env python3
"""Run an isolated Swift Testing proof against the production fetch coordinator."""
from pathlib import Path
import argparse
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--output', default=str(Path(__file__).resolve().parent.parent / '.build/verification/remote-markdown-admission.log'))
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
source = (root / 'Sources/awesoMux/Services/RemoteMarkdownSnapshotFetcher.swift').read_text()
coordinator = source[source.index('final class RemoteMarkdownFetchCoordinator:'):source.index('struct RemoteMarkdownSnapshotFetcher:')]
stubs = '''import Foundation
import Testing
struct RemoteTarget: Hashable, Sendable { let sshDestination: String }
struct ResourceIdentity: Hashable, Sendable { let remoteTarget: RemoteTarget?; let path: String }
enum RemoteMarkdownTransport: Hashable, Sendable { case managed, unmanaged }
struct RemoteMarkdownFetchOutcome: Sendable {}
'''
proof = r'''
@MainActor
@Suite("Queued remote Markdown admission proof", .serialized)
struct AdmissionProof {
    @MainActor final class State {
        var valid = true
        var commands = 0
        var caches = 0
        var joined: RemoteMarkdownFetchCoordinator.PreparedAttempt?
        var didJoin = false
    }
    actor Gate {
        var opened = false
        var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func open() {
            opened = true
            let pending = waiters
            waiters = []
            pending.forEach { $0.resume() }
        }
    }
    func key(_ path: String, directory: String) -> RemoteMarkdownFetchCoordinator.Key {
        .init(identity: .init(remoteTarget: .init(sshDestination: "proof"), path: path), cacheDirectoryPath: directory)
    }
    func operation(_ state: State) async -> RemoteMarkdownFetchOutcome? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        do { try process.run(); process.waitUntilExit() } catch { Issue.record("subprocess failed: \(error)"); return nil }
        state.commands += 1
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("admission-cache-\(UUID()).md")
        do { try Data("# proof".utf8).write(to: cache); state.caches += 1; try FileManager.default.removeItem(at: cache) }
        catch { Issue.record("cache effect failed: \(error)") }
        return RemoteMarkdownFetchOutcome()
    }
    func blocker(_ coordinator: RemoteMarkdownFetchCoordinator, directory: String, gate: Gate) -> RemoteMarkdownFetchCoordinator.PreparedAttempt {
        coordinator.prepare(for: key("block", directory: directory)) { await gate.wait(); return nil }
    }
    @Test func invalidSoleOrigin() async {
        let coordinator = RemoteMarkdownFetchCoordinator(), state = State(), gate = Gate()
        let directory = UUID().uuidString
        let blocked = blocker(coordinator, directory: directory, gate: gate)
        let queued = coordinator.prepare(for: key("file", directory: directory), admission: { state.valid }) { await operation(state) }
        state.valid = false
        await gate.open()
        _ = await blocked.value()
        #expect(await queued.value().outcome == nil)
        #expect(state.commands == 0 && state.caches == 0)
    }
    @Test func allOriginsInvalid() async {
        let coordinator = RemoteMarkdownFetchCoordinator(), leader = State(), follower = State(), effects = State(), gate = Gate()
        let directory = UUID().uuidString
        let blocked = blocker(coordinator, directory: directory, gate: gate)
        let identity = key("file", directory: directory)
        let first = coordinator.prepare(for: identity, admission: { leader.valid }) { await operation(effects) }
        let second = coordinator.prepare(for: identity, admission: { follower.valid }) { await operation(effects) }
        leader.valid = false; follower.valid = false
        await gate.open(); _ = await blocked.value()
        #expect(await first.value().outcome == nil)
        #expect(await second.value().outcome == nil)
        #expect(effects.commands == 0 && effects.caches == 0)
    }
    @Test func cancelledLeaderKeepsValidFollower() async {
        let coordinator = RemoteMarkdownFetchCoordinator(), leader = State(), follower = State(), effects = State(), gate = Gate()
        let directory = UUID().uuidString
        let blocked = blocker(coordinator, directory: directory, gate: gate)
        let identity = key("file", directory: directory)
        let first = coordinator.prepare(for: identity, admission: { leader.valid }) { await operation(effects) }
        let second = coordinator.prepare(for: identity, admission: { follower.valid }) { await operation(effects) }
        leader.valid = false
        await gate.open(); _ = await blocked.value()
        #expect(await first.value().outcome != nil)
        #expect(await second.value().outcome != nil)
        #expect(effects.commands == 1 && effects.caches == 1)
    }
    @Test func joinDuringRejectionRetriesRevision() async {
        let coordinator = RemoteMarkdownFetchCoordinator(), state = State(), gate = Gate()
        let directory = UUID().uuidString, identity = key("file", directory: directory)
        let blocked = blocker(coordinator, directory: directory, gate: gate)
        let first = coordinator.prepare(for: identity, admission: {
            if !state.didJoin {
                state.didJoin = true
                state.joined = coordinator.prepare(for: identity, admission: { true }) { await operation(state) }
            }
            return false
        }) { await operation(state) }
        await gate.open(); _ = await blocked.value()
        #expect(await first.value().outcome != nil)
        #expect(state.joined?.cohort === first.cohort)
        #expect(state.commands == 1 && state.caches == 1)
    }
    @Test func oldGenerationCannotRemoveReplacement() async {
        let coordinator = RemoteMarkdownFetchCoordinator(), state = State(), predecessor = Gate(), running = Gate()
        let directory = UUID().uuidString, identity = key("file", directory: directory)
        let blocked = blocker(coordinator, directory: directory, gate: predecessor)
        let old = coordinator.prepare(for: identity, admission: { false }) { await operation(state) }
        #expect(await old.cohort.admit() == false)
        let replacement = coordinator.prepare(for: identity, admission: { true }) { await running.wait(); return await operation(state) }
        #expect(old.cohort !== replacement.cohort)
        await predecessor.open(); _ = await blocked.value(); _ = await old.value()
        let joined = coordinator.prepare(for: identity, admission: { true }) { await operation(state) }
        #expect(joined.cohort === replacement.cohort)
        await running.open(); _ = await replacement.value(); _ = await joined.value()
        #expect(state.commands == 1 && state.caches == 1)
    }
    @Test(arguments: [false, true]) func staleLoadingOwnerTransfersOneOutcome(unavailable: Bool) async {
        let coordinator = RemoteMarkdownFetchCoordinator(), leader = State(), follower = State(), effects = State(), gate = Gate()
        let directory = UUID().uuidString, identity = key("file", directory: directory), workspace = UUID()
        let blocked = blocker(coordinator, directory: directory, gate: gate)
        let first = coordinator.prepare(for: identity, consumer: unavailable ? .document : .refresh, announcementSessionID: workspace, admission: { leader.valid }) {
            let result = await operation(effects); return unavailable ? nil : result
        }
        let second = coordinator.prepare(for: identity, consumer: unavailable ? .refresh : .document, announcementSessionID: workspace, admission: { follower.valid }) {
            let result = await operation(effects); return unavailable ? nil : result
        }
        #expect(first.ownsAnnouncements && !second.ownsAnnouncements)
        leader.valid = false
        await gate.open(); _ = await blocked.value(); _ = await first.value(); _ = await second.value()
        #expect(second.cohort.claimOutcome(sessionID: workspace))
        #expect(!second.cohort.claimOutcome(sessionID: workspace))
        #expect(second.cohort.claimOutcome(sessionID: UUID()))
        #expect(effects.commands == 1 && effects.caches == 1)
    }
    @Test func changedOriginRejectsDisplayAfterStart() async {
        let coordinator = RemoteMarkdownFetchCoordinator(), state = State()
        let fetched = coordinator.prepare(for: key("file", directory: UUID().uuidString), admission: { state.valid }) {
            let outcome = await operation(state)
            await MainActor.run { state.valid = false }
            return outcome
        }
        let outcome = await fetched.value().outcome
        let displayed = outcome != nil && state.valid
        #expect(!displayed)
        #expect(state.commands == 1 && state.caches == 1)
    }
}
'''
with tempfile.TemporaryDirectory(prefix='markdown-admission-proof-') as directory:
    directory = Path(directory)
    (directory / 'Tests/AdmissionProof').mkdir(parents=True)
    (directory / 'Package.swift').write_text('// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: "AdmissionProof", targets: [.testTarget(name: "AdmissionProof")])\n')
    (directory / 'Tests/AdmissionProof/AdmissionProof.swift').write_text(stubs + coordinator + proof)
    result = subprocess.run(['swift', 'test', '--package-path', str(directory)], text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    Path(args.output).parent.mkdir(parents=True, exist_ok=True)
    Path(args.output).write_text(result.stdout)
    print(result.stdout[-12000:])
    print(f'Proof artifact: {args.output}')
    raise SystemExit(result.returncode)
