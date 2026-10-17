#!/usr/bin/env python3
"""Exercise production connectivity invalidation with a live SSH stream.

This is a diagnostic integration run, not the repository preflight or native UI
verification. It compiles the actual core and service sources in a disposable
package; no production profile, network interface, or remote files are changed.
"""

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile


PROOF = r'''
import AppKit
import AwesoMuxCore
import Foundation

actor ProbeGate {
    var started = 0
    var released = false
    var waiters: [CheckedContinuation<RemoteForegroundLivenessSample?, Never>] = []
    func sample() async -> RemoteForegroundLivenessSample? {
        started += 1
        if released { return .init(liveness: .liveCommand) }
        return await withCheckedContinuation { waiters.append($0) }
    }
    func count() -> Int { started }
    func release() {
        released = true
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume(returning: .init(liveness: .liveCommand)) }
    }
}

@main struct ConnectivityProof {
    @MainActor static func main() async throws {
        var failures = 0
        func check(_ condition: Bool, _ name: String) {
            print("\(condition ? "PASS" : "FAIL") \(name)")
            if !condition { failures += 1 }
        }
        let target = RemoteTarget(parsing: CommandLine.arguments[1])!
        let managed = TerminalPane(title: "static task", workingDirectory: "/tmp", executionPlan: .ssh(SSHExecution(target: target)))
        var ordinary = TerminalPane(title: "agent", workingDirectory: "/tmp", executionPlan: .local)
        ordinary.remoteHost = target.sshDestination
        var contextOnly = TerminalPane(title: "files", workingDirectory: "/tmp", executionPlan: .local)
        contextOnly.remoteFileContext = RemoteFileContext(target: target, baseDirectory: "/tmp")
        let local = TerminalPane(title: "local", workingDirectory: "/tmp", executionPlan: .local)
        let panes = [managed, ordinary, contextOnly, local]
        let sessions = panes.map { TerminalSession(title: $0.title, workingDirectory: "/tmp", layout: .pane($0), activePaneID: $0.id) }
        let store = SessionStore(groups: [SessionGroup(name: "diagnostic", sessions: sessions)], selectedSessionID: sessions[0].id)
        func current(_ index: Int) -> TerminalPane { store.session(id: sessions[index].id)!.layout.pane(id: panes[index].id)! }
        let authorizer = RemoteMarkdownReadAuthorization()
        let before = RemoteMarkdownReadOrigin(sessionID: sessions[0].id, pane: current(0))
        let attempt = authorizer.authorizeDeclared(origin: before)!
        check(authorizer.consumeBeforeFetch(attempt, currentOrigin: before), "declared file read begins before connectivity event")
        let center = NotificationCenter()
        let observer = RemoteConnectivityObserver(notificationCenter: center) {
            #if BASELINE
            store.markRemotePanesPossiblyStale()
            #else
            store.invalidateRemoteConnectivityEvidence()
            #endif
        }

        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=6", target.sshDestination,
            "printf 'BEFORE\\n'; sleep 2; printf 'AFTER-no-title\\n'"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        var first = Data()
        while !first.contains(0x0A), let chunk = try output.fileHandleForReading.read(upToCount: 1), !chunk.isEmpty { first.append(chunk) }
        check(String(decoding: first, as: UTF8.self) == "BEFORE\n", "real SSH stream connected before event")
        check(process.isRunning, "same SSH process remains running at event")
        observer.recordConnectivitySignal()
        // Baseline deferred the false warning by one second. Waiting past that
        // deadline gives both implementations the same observable checkpoint.
        try await Task.sleep(for: .milliseconds(1200))
        check(current(0).remoteConnectionHealth == .active, "managed SSH stays active without a title event")
        check(current(1).remoteConnectionHealth == .active, "ordinary SSH stays active without a title event")
        check(current(3).remoteConnectionHealth == .active, "local pane remains active")
        let rest = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        check(process.terminationStatus == 0 && String(decoding: rest, as: UTF8.self).contains("AFTER-no-title"), "same real SSH stream delivers response after event without OSC titles")
        check(!authorizer.validateAfterFetch(attempt, currentOrigin: RemoteMarkdownReadOrigin(sessionID: sessions[0].id, pane: current(0))), "pre-event file read cannot apply after event")
        check(current(0).executionPlan == managed.executionPlan && current(1).remoteHost == ordinary.remoteHost,
            "execution authority and observed SSH identity are preserved")

        #if !BASELINE
        let firstEpoch = current(0).remoteConnectivityEpoch
        let localEpoch = current(3).remoteConnectivityEpoch
        let contextEpoch = contextOnly.remoteConnectivityEpoch
        check(current(2).remoteConnectivityEpoch != contextEpoch, "file-context-only pane invalidates without remote index membership")
        let newOrigin = RemoteMarkdownReadOrigin(sessionID: sessions[0].id, pane: current(0))
        let secondAttempt = authorizer.authorizeDeclared(origin: newOrigin)!
        check(authorizer.consumeBeforeFetch(secondAttempt, currentOrigin: newOrigin), "fresh file read begins after event")
        observer.recordConnectivitySignal()
        check(current(0).remoteConnectivityEpoch != firstEpoch, "repeated event invalidates even without cached liveness")
        check(current(3).remoteConnectivityEpoch == localEpoch, "unrelated local epoch is unchanged")
        check(!authorizer.validateAfterFetch(secondAttempt, currentOrigin: RemoteMarkdownReadOrigin(sessionID: sessions[0].id, pane: current(0))), "second event revokes a newly started read")
        store.updatePane(sessionID: sessions[0].id, paneID: managed.id, title: "Work")
        check(current(0).remoteConnectivityEpoch != firstEpoch, "static title cannot undo connectivity invalidation")
        let encoded = try JSONEncoder().encode(current(0))
        check(!String(decoding: encoded, as: UTF8.self).contains("remoteConnectivityEpoch"), "connectivity epoch is not persisted")

        let gate = ProbeGate()
        let poller = RemoteLivenessPoller(probe: { _ in await gate.sample() })
        let oldKey = RemoteLivenessPoller.Key(workspaceID: sessions[0].id, paneID: managed.id, generation: "same-attach", remoteConnectivityEpoch: firstEpoch)
        let newKey = RemoteLivenessPoller.Key(workspaceID: sessions[0].id, paneID: managed.id, generation: "same-attach", remoteConnectivityEpoch: current(0).remoteConnectivityEpoch)
        let oldProbe = Task { await poller.sample(key: oldKey, command: "old") }
        let newProbe = Task { await poller.sample(key: newKey, command: "new") }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await gate.count() < 2, ContinuousClock.now < deadline { await Task.yield() }
        check(await gate.count() == 2, "post-event probe does not coalesce with pre-event work")
        await gate.release()
        _ = await (oldProbe.value, newProbe.value)
        #endif
        print("RESULT \(failures == 0 ? "PASS" : "FAIL") failures=\(failures)")
        if failures != 0 { exit(1) }
    }
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", required=True, help="Existing SSH alias with noninteractive access")
    parser.add_argument("--source-root", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--baseline", action="store_true", help="Exercise the pre-fix observer and facade")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    root = args.source_root.resolve()
    services = ["RemoteConnectivityObserver", "RemoteMarkdownReadAuthorization", "RemoteLivenessPoller", "RemoteLivenessProbe", "BoundedProcessRunner", "OneShotFlag"]
    with tempfile.TemporaryDirectory(prefix="awesomux-connectivity-proof-") as directory:
        package = Path(directory)
        sources = package / "Sources"
        sources.mkdir()
        for name in ["AwesoMuxCore", "AwesoMuxBridgeProtocol", "AwesoMuxLocalAPI", "UnicodeHygiene", "SecureFileIO"]:
            (sources / name).symlink_to(root / "Sources" / name)
        proof = sources / "ConnectivityProof"
        proof.mkdir()
        fingerprints = {str(source.relative_to(root)): hashlib.sha256(source.read_bytes()).hexdigest()
                        for source in sorted((root / "Sources/AwesoMuxCore").rglob("*.swift"))}
        for name in services:
            source = root / "Sources/awesoMux/Services" / (name + ".swift")
            shutil.copyfile(source, proof / source.name)
            fingerprints[name] = hashlib.sha256(source.read_bytes()).hexdigest()
        (proof / "Proof.swift").write_text(PROOF)
        condition = ', swiftSettings: [.define("BASELINE")]' if args.baseline else ""
        (package / "Package.swift").write_text('''// swift-tools-version: 6.3
import PackageDescription
let package = Package(name: "ConnectivityProof", platforms: [.macOS(.v15)],
    dependencies: [.package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.8.0")], targets: [
    .target(name: "UnicodeHygiene"), .target(name: "SecureFileIO"),
    .target(name: "AwesoMuxBridgeProtocol", dependencies: ["UnicodeHygiene"]),
    .target(name: "AwesoMuxLocalAPI"),
    .target(name: "AwesoMuxCore", dependencies: ["AwesoMuxBridgeProtocol", "AwesoMuxLocalAPI", "SecureFileIO", "UnicodeHygiene", .product(name: "Markdown", package: "swift-markdown")], linkerSettings: [.linkedLibrary("sqlite3")]),
    .executableTarget(name: "ConnectivityProof", dependencies: ["AwesoMuxCore", "AwesoMuxBridgeProtocol"]CONDITION)
])
'''.replace("CONDITION", condition))
        result = subprocess.run(["swift", "run", "--package-path", str(package), "ConnectivityProof", args.host], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=300)
        report = "Diagnostic integration: actual core and services, real SSH, synthetic connectivity signal.\nNative UI and full preflight are separate checks.\n"
        report += json.dumps({"source_root": str(root), "baseline": args.baseline, "sources_sha256": fingerprints}, indent=2) + "\n" + result.stdout
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(report)
        print(report)
        print(f"Artifact: {args.output}")
        return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
