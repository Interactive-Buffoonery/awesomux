import Foundation
import Testing
@testable import awesoMux
@testable import AwesoMuxCore

/// INT-185: the quit-risk scan issue's premise was that per-session libproc
/// probing is the felt "quitting feels slow" bottleneck. These benchmarks are
/// the "measure first" the issue asked for. The actual bottleneck found
/// (fixed alongside this test — see `GhosttyRuntime.currentTerminalQuitConfirmationSnapshots`)
/// was NOT the per-probe cost; it was the quit path resampling the shared
/// surface set once per consuming store, unbounded in floating-slot count.
/// These tests measure the per-probe component in isolation, across the
/// probe shapes production actually exercises — not a proof the whole quit
/// path is fast. Libghostty FFI reads, OSC-133 prompt-marker sampling, and
/// `SessionPersistence.flush` remain unmeasured; they need a live app/surface
/// to exercise and are out of scope here.
///
/// Deliberately NOT asserting an internal probe-call COUNT via a spy: doing
/// so would need a protocol/mock seam around the concrete `GhosttyRuntime`
/// class purely for this one test, which is more machinery than the fix
/// warrants. The fan-out fix's actual safety property (a store ignores
/// snapshot entries for paneIDs it doesn't own) is unit-tested directly in
/// `QuitRiskTests.sharedSnapshotListIgnoresForeignPaneIDs` instead — a
/// stronger, cheaper guard than counting calls would have been.
@Suite("Quit-risk scan probe benchmark (INT-185)")
struct ProcessLivenessProbeQuitScanBenchmarkTests {
    /// ~50-100x the measured baseline (idle-shell shape measured ~0.3ms for
    /// 20 units during plan review) — generous enough to absorb CI-runner
    /// variance without the assertion flapping, while still catching a real
    /// regression (e.g. someone adding a subprocess spawn to the probe path).
    /// A rough order-of-magnitude sanity bound (Nielsen's ~100ms "stays in
    /// flow" threshold is the budget this is checking against with margin to
    /// spare), not a phase-by-phase latency SLA — a formal budget per
    /// quit-path phase would be disproportionate for one probe component
    /// measured in isolation.
    private static let sweepThresholdNanos: Double = 20_000_000

    private static let sessionCount = 20
    private static let sweepIterations = 50

    /// Spawns `sessionCount` real `/bin/sh` processes blocked on the `read`
    /// builtin (no children — the idle-at-prompt shape) and times the exact
    /// `ProcessLivenessProbe` calls `GhosttySurfaceNSView.foregroundProcessLiveness()`
    /// makes for a non-bridged pane: `foregroundComm`, then `hasChildren`
    /// gated on `ShellRecognition.isRecognizedShell`.
    @Test("idle recognized-shell shape stays under the perceptibility budget")
    func idleShellShapeIsCheap() throws {
        let processes = try (0..<Self.sessionCount).map { _ in try Self.spawnIdleShell() }
        defer { processes.forEach { $0.terminate() } }

        let avgNanos = Self.timedSweep(pids: processes.map(\.processIdentifier)) { pid in
            let comm = ProcessLivenessProbe.foregroundComm(pid: pid)
            if let comm, ShellRecognition.isRecognizedShell(comm) {
                _ = ProcessLivenessProbe.hasChildren(pid: pid)
            }
        }

        Self.report("idle shell", sweepNanos: avgNanos)
        #expect(avgNanos < Self.sweepThresholdNanos)
    }

    /// Spawns `sessionCount` `sh` processes each with one live child (a
    /// background `sleep`) — the heavier `proc_listpids` buffer-fill path
    /// `hasChildren` takes when the zero-result fast path doesn't apply.
    @Test("busy recognized-shell-with-children shape stays under the perceptibility budget")
    func busyShellShapeIsCheap() throws {
        let processes = try (0..<Self.sessionCount).map { _ in try Self.spawnShellWithChild() }
        defer {
            for process in processes {
                process.parent.terminate()
                kill(process.childPID, SIGTERM)
            }
        }

        let avgNanos = Self.timedSweep(pids: processes.map { $0.parent.processIdentifier }) { pid in
            let comm = ProcessLivenessProbe.foregroundComm(pid: pid)
            if let comm, ShellRecognition.isRecognizedShell(comm) {
                _ = ProcessLivenessProbe.hasChildren(pid: pid)
            }
        }

        Self.report("busy shell (with children)", sweepNanos: avgNanos)
        #expect(avgNanos < Self.sweepThresholdNanos)
    }

    /// Spawns `sessionCount` daemon-shaped process trees (daemon → recognized
    /// shell → child) and times `ProcessLivenessProbe.bridgedLiveness`, the
    /// heavier path bridged panes take (walks the daemon's children, then
    /// each child's own children — two `childPIDs` calls plus a `comm` read
    /// per bridged pane, vs. one `comm` + one `hasChildren` for a plain pane).
    @Test("bridged daemon-tree shape stays under the perceptibility budget")
    func bridgedShapeIsCheap() throws {
        let processes = try (0..<Self.sessionCount).map { _ in try Self.spawnBridgedDaemonTree() }
        defer { processes.forEach { $0.terminate() } }

        let avgNanos = Self.timedSweep(pids: processes.map(\.processIdentifier)) { daemonPID in
            _ = ProcessLivenessProbe.bridgedLiveness(daemonPID: daemonPID)
        }

        Self.report("bridged daemon tree", sweepNanos: avgNanos)
        #expect(avgNanos < Self.sweepThresholdNanos)
    }

    /// The reducer/apply step is pure Swift (no syscalls, no FFI) — cheap to
    /// benchmark honestly rather than leaving it as an unmeasured assumption.
    /// Named in cross-model review as a cost component the libproc-only
    /// benchmark doesn't cover.
    @Test("reducer apply over a realistic session count stays under the perceptibility budget")
    func reducerApplyIsCheap() {
        var groups = [
            SessionGroup(
                name: "main",
                sessions: (0..<Self.sessionCount).map { index in
                    TerminalSession(title: "session-\(index)", workingDirectory: "~", agentKind: .shell)
                }
            )
        ]
        let snapshots = groups[0].sessions.map { session in
            TerminalQuitConfirmationSnapshot(
                sessionID: session.id,
                paneID: session.activePaneID,
                needsConfirmation: true
            )
        }

        var totalNanos: UInt64 = 0
        for _ in 0..<Self.sweepIterations {
            let start = DispatchTime.now()
            _ = TerminalQuitConfirmationReducer.apply(
                risksByPaneID: TerminalQuitConfirmationReducer.risks(from: snapshots),
                promptObservedByPaneID: TerminalQuitConfirmationReducer.promptObserved(from: snapshots),
                livenessByPaneID: TerminalQuitConfirmationReducer.liveness(from: snapshots),
                to: &groups
            )
            totalNanos += DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
        }
        let avgNanos = Double(totalNanos) / Double(Self.sweepIterations)

        Self.report("reducer apply", sweepNanos: avgNanos)
        #expect(avgNanos < Self.sweepThresholdNanos)
    }

    // MARK: - Helpers

    /// `/bin/sh -c "read x"`, fed by a pipe we hold open and never write to
    /// or close — `read` is a shell BUILTIN, so unlike an external command it
    /// is never eligible for the shell's tail-call exec optimization. Verified
    /// empirically with `ps`: `/bin/sh -c "sleep 30"` execs INTO `sleep`,
    /// replacing the shell's process image entirely (comm becomes "sleep",
    /// not "sh") — a fixture built on that would silently skip the
    /// `hasChildren` syscall this shape exists to exercise, since "sleep"
    /// isn't a recognized shell name (review finding). `read x` has no such
    /// exec path and blocks indefinitely once its stdin pipe's write end
    /// stays open, with zero children.
    private static func spawnIdleShell() throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "read x"]
        process.standardInput = Pipe()  // never written to or closed — keeps `read` blocked
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    /// Verified-shape 3-level daemon → shell → child tree (`sh -c "sh -c
    /// 'sleep 5 & wait' & wait"`), mirroring what `bridgedLiveness(daemonPID:)`
    /// actually walks in production: the daemon's child must ITSELF be a
    /// recognized shell for the walk to reach a second `childPIDs` call. A
    /// flatter 2-level fixture (daemon directly parenting `sleep`) is wrong —
    /// "sleep" isn't a recognized shell name, so `bridgedLiveness`
    /// short-circuits to `.bridgedBusy` at the first hop without exercising
    /// the shape production actually walks (review finding — verified
    /// empirically with `ps`).
    ///
    /// Uses a 5s sleep, not 30s: SIGTERM on the outer `sh` does not cascade to
    /// the inner `sh`/`sleep` (no shared process group set up here), so any
    /// descendant orphaned by `terminate()` self-reaps within a few seconds
    /// instead of lingering for a full 30s.
    /// ponytail: bounded orphan window, not zero-orphan — revisit with
    /// explicit pid capture + individual kills if leaked processes ever
    /// become a real problem (e.g. a much larger stress-count variant).
    private static func spawnBridgedDaemonTree() throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sh -c 'sleep 5 & wait' & wait"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    private static func spawnShellWithChild() throws -> (parent: Process, childPID: pid_t) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Backgrounds a sleep, prints its pid, then waits on it — so the
        // shell (the "daemon root") has exactly one live child for the
        // duration of the benchmark, mirroring a bridged session's root shell.
        process.arguments = ["-c", "sleep 30 & echo $!; wait"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()

        let data = stdout.fileHandleForReading.availableData
        guard
            let line = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            let childPID = pid_t(line)
        else {
            throw ProbeShapeSetupError.childPIDUnreadable
        }
        return (process, childPID)
    }

    /// Spawn-once, warm-up-once, then time N repeated sweeps over the SAME
    /// live pids. Process spawn (fork/exec, tens of ms) must never land
    /// inside the timed region — it would swamp the microsecond-scale probe
    /// cost this benchmark exists to measure.
    private static func timedSweep(pids: [pid_t], probe: (pid_t) -> Void) -> Double {
        for pid in pids { probe(pid) }  // untimed warm-up: first syscalls can page-fault/cache-fill

        var totalNanos: UInt64 = 0
        for _ in 0..<sweepIterations {
            let start = DispatchTime.now()
            for pid in pids { probe(pid) }
            totalNanos += DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
        }
        return Double(totalNanos) / Double(sweepIterations)
    }

    private static func report(_ shape: String, sweepNanos: Double) {
        let perUnitMicros = sweepNanos / Double(sessionCount) / 1000
        print(
            "[INT-185] \(shape): \(sweepNanos / 1_000_000)ms/sweep (\(sessionCount) units, \(perUnitMicros)µs/unit)"
        )
    }

    private enum ProbeShapeSetupError: Error {
        case childPIDUnreadable
    }
}
