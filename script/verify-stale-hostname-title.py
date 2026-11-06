#!/usr/bin/env python3
"""Check that a stale local hostname in a local shell title stays local (#698).

This is a diagnostic integration run, not the repository preflight or native UI
verification. It compiles the actual core sources and the app's process probe in
a disposable package, then drives a real interactive zsh on a real pty. The SSH
case runs a real `ssh` client with a local sleep ProxyCommand, so no remote host
is contacted.
"""

import argparse
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import pty
import shutil
import signal
import time
import subprocess
import tempfile
import threading


PROOF = r'''
import AwesoMuxCore
import Darwin
import Foundation

@main struct StaleHostnameProof {
    @MainActor static func main() async throws {
        var failures = 0
        func check(_ condition: Bool, _ name: String) {
            print("\(condition ? "PASS" : "FAIL") \(name)")
            if !condition { failures += 1 }
        }
        let shellPID = pid_t(CommandLine.arguments[1])!
        let terminal = FileHandle(fileDescriptor: Int32(CommandLine.arguments[2])!, closeOnDealloc: false)
        let staleTitle = CommandLine.arguments[3]

        // Mirrors the non-bridged app sampler: libghostty reports the terminal's
        // foreground pid, and the probe asks whether that is an idle local shell.
        func foregroundPID() -> pid_t? { ProcessLivenessProbe.terminalForegroundProcessGroup(pid: shellPID) }
        func localShellOwnsTerminal() -> Bool {
            foregroundPID().map { ProcessLivenessProbe.localShellOwnsTerminal(shellPID: $0) } ?? false
        }
        func waitUntil(_ condition: () -> Bool) async {
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        }

        let pane = TerminalPane(title: "zsh", workingDirectory: NSHomeDirectory(), executionPlan: .local)
        let session = TerminalSession(title: "local", workingDirectory: NSHomeDirectory(), layout: .pane(pane), activePaneID: pane.id)
        let store = SessionStore(groups: [SessionGroup(name: "diagnostic", sessions: [session])], selectedSessionID: session.id)
        func current() -> TerminalPane { store.session(id: session.id)!.layout.pane(id: pane.id)! }
        func report(_ title: String) {
            // Same process evidence the app's title commit passes.
            store.updatePane(sessionID: session.id, paneID: pane.id, title: title,
                             localShellOwnsTerminal: localShellOwnsTerminal())
            print("title \(title.debugDescription) -> remotePresentationHost=\(current().remotePresentationHost ?? "nil")")
        }

        let localNames = LocalHostnames.resolve()
        print("local hostnames: \(localNames.sorted())")
        var staleHost: String?
        if case let .remote(host) = RemoteSessionDetector.detect(title: staleTitle, localNames: localNames) {
            staleHost = host
        }
        check(staleHost != nil, "detector alone reads the stale hostname as foreign (precondition)")

        await waitUntil(localShellOwnsTerminal)
        check(localShellOwnsTerminal(), "real local zsh owns its terminal at the prompt")
        report(staleTitle)
        check(current().remotePresentationHost == nil, "stale local hostname title stays local")
        store.clearManagedSSHObservationIfExitedToLocalShell(
            sessionID: session.id, paneID: pane.id, liveness: .idleShell,
            foregroundCommand: "zsh", localShellOwnsTerminal: localShellOwnsTerminal())
        check(current().remotePresentationHost == nil, "existing idle-shell sampler clears the observation")
        report(staleTitle)
        check(current().remotePresentationHost == nil, "repeated stale title cannot rearm false remote state")
        terminal.write(Data("/bin/sleep 30\n".utf8))
        await waitUntil { foregroundPID().flatMap(ProcessLivenessProbe.foregroundComm(pid:)) == "sleep" }
        check(!localShellOwnsTerminal(), "local command now owns the foreground")
        report("codex")
        check(current().remotePresentationHost == nil, "agent's indeterminate title keeps the pane local")

        terminal.write(Data([3]))
        await waitUntil(localShellOwnsTerminal)
        check(localShellOwnsTerminal(), "local command exits back to the real shell")

        terminal.write(Data("ssh -F /dev/null -o BatchMode=yes -o 'ProxyCommand=/bin/sleep 30' example.invalid\n".utf8))
        await waitUntil { foregroundPID().flatMap(ProcessLivenessProbe.foregroundComm(pid:)) == "ssh" }
        let foreground = foregroundPID().flatMap(ProcessLivenessProbe.foregroundComm(pid:))
        check(foreground == "ssh" && !localShellOwnsTerminal(), "real ssh client owns the terminal (got \(foreground ?? "nil"))")
        report("example@build-server:~")
        check(current().remotePresentationHost == "build-server", "foreign title with ssh in the foreground is still remote")
        report("codex")
        check(current().remotePresentationHost == "build-server", "indeterminate remote agent title remains sticky")
        report(staleTitle)
        check(staleHost != nil && current().remotePresentationHost == staleHost,
            "the same stale name is remote when ssh owns the terminal")

        terminal.write(Data([3]))
        await waitUntil(localShellOwnsTerminal)
        check(localShellOwnsTerminal(), "SSH exits back to local zsh")
        store.clearManagedSSHObservationIfExitedToLocalShell(
            sessionID: session.id, paneID: pane.id, liveness: .idleShell,
            foregroundCommand: "zsh", localShellOwnsTerminal: localShellOwnsTerminal())
        report(staleTitle)
        check(current().remotePresentationHost == nil, "post-SSH stale title stays local again")
        check(current().executionPlan == .local && current().workingDirectory == NSHomeDirectory(),
            "runtime presentation never changes local execution authority or cwd")

        terminal.write(Data("exit\n".utf8))
        print("RESULT \(failures == 0 ? "PASS" : "FAIL") failures=\(failures)")
        if failures != 0 { exit(1) }
    }
}
'''

# Depends on the checkout's own AwesoMuxCore product (via the `awesomux`
# symlink) so the proof tracks the real target graph and dependency pins.
PACKAGE = '''// swift-tools-version: 6.3
import PackageDescription
let package = Package(name: "StaleHostnameProof", platforms: [.macOS(.v15)],
    dependencies: [.package(path: "awesomux")],
    targets: [.executableTarget(name: "StaleHostnameProof",
                                dependencies: [.product(name: "AwesoMuxCore", package: "awesomux")])])
'''


@contextmanager
def disposable_package():
    directory = tempfile.mkdtemp(prefix="awesomux-stale-hostname-proof-")
    try:
        yield directory
    finally:
        subprocess.run(["trash", directory], check=True)


def stop_shell(shell_pid, master):
    # Signal only this fixture's PTY foreground job and shell, including a
    # ProxyCommand child if an assertion or build/runtime exception interrupts it.
    try:
        foreground = os.tcgetpgrp(master)
    except OSError:
        foreground = shell_pid
    groups = {shell_pid, foreground} - {0, os.getpgrp()}
    for group in groups:
        try:
            os.killpg(group, signal.SIGTERM)
        except (ProcessLookupError, PermissionError):  # macOS: EPERM for a zombie-only group
            pass
    deadline = time.monotonic() + 2
    reaped = False
    while time.monotonic() < deadline:
        if os.waitpid(shell_pid, os.WNOHANG)[0]:
            reaped = True
            break
        time.sleep(0.05)
    for group in groups:
        try:
            os.killpg(group, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):  # macOS: EPERM for a zombie-only group
            pass
    if not reaped:
        os.waitpid(shell_pid, 0)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--baseline", action="store_true", help="Label the pre-fix reproduction")
    parser.add_argument("--stale-title", default="example@syn-172-100-12-34:~")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    root = args.source_root.resolve()
    with disposable_package() as directory:
        package = Path(directory)
        sources = package / "Sources"
        sources.mkdir()
        (package / "awesomux").symlink_to(root)
        proof = sources / "StaleHostnameProof"
        proof.mkdir()
        probe = root / "Sources/awesoMux/Services/ProcessLivenessProbe.swift"
        shutil.copyfile(probe, proof / probe.name)
        fingerprints = {str(source.relative_to(root)): hashlib.sha256(source.read_bytes()).hexdigest()
                        for source in sorted((root / "Sources/AwesoMuxCore").rglob("*.swift")) + [probe]}
        (proof / "Proof.swift").write_text(PROOF)
        (package / "Package.swift").write_text(PACKAGE)
        build = subprocess.run(["swift", "build", "--package-path", str(package), "--product", "StaleHostnameProof"],
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=900)
        # Compiler invocations are huge; keep the diagnostics, not the command lines.
        output = "\n".join(line for line in build.stdout.splitlines() if "error:" in line)[-4000:] if build.returncode else ""
        returncode = build.returncode
        if build.returncode == 0:
            shell_pid, master = pty.fork()
            if shell_pid == 0:
                os.execve("/bin/zsh", ["zsh", "-f", "-i"], {"PATH": "/usr/bin:/bin", "HOME": os.environ["HOME"], "TERM": "xterm-256color"})
            transcript = bytearray()

            def drain():
                while True:
                    try:
                        chunk = os.read(master, 4096)
                    except OSError:
                        return
                    if not chunk:
                        return
                    transcript.extend(chunk)

            reader = threading.Thread(target=drain, daemon=True)
            reader.start()
            try:
                run = subprocess.run([str(package / ".build/debug/StaleHostnameProof"), str(shell_pid), str(master), args.stale_title],
                                     pass_fds=(master,), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=120)
                output, returncode = run.stdout, run.returncode
            finally:
                stop_shell(shell_pid, master)
                reader.join(timeout=2)
                os.close(master)
            output += "\n--- pty transcript ---\n" + transcript.decode(errors="replace")
        report = ("Diagnostic integration: actual core sources and ProcessLivenessProbe, real local zsh on a pty,\n"
                  "real ssh client using a local sleep ProxyCommand (no network). Native UI and full preflight are separate checks.\n")
        report += json.dumps({"source_root": str(root), "baseline": args.baseline, "stale_title": args.stale_title,
                              "commit": subprocess.check_output(["git", "-C", str(root), "rev-parse", "HEAD"], text=True).strip(),
                              "sources_sha256": hashlib.sha256(json.dumps(fingerprints, sort_keys=True).encode()).hexdigest()}, indent=2) + "\n" + output
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(report)
        print(report)
        print(f"Artifact: {args.output}")
        return returncode


if __name__ == "__main__":
    raise SystemExit(main())
