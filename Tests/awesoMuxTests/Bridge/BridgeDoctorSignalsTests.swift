import AwesoMuxCore
import Foundation
import Testing
@testable import awesoMux

// All coverage runs against the injected closure seams — no live ssh, no real
// socket binds. A spy exec channel records the exact assembled probe commands
// (and injects per-command failures / outputs); the pure interpretation
// functions are tested directly.
@Suite("Bridge doctor signals")
struct BridgeDoctorSignalsTests {
    private static let context = BridgeDoctorSignals.Context(
        controlPath: "/tmp/ctl/%C",
        remote: RemoteTarget(user: "ed", host: "box"),
        helperPath: "/home/ed/.awesomux/bin/awesomux-bridge-helper",
        session: TerminalSessionID(rawValue: "abc-session")!,
        stateFilePath: "/home/ed/.awesomux/bridge/abc-session.json"
    )

    // MARK: - Pure: version intersection (fail-closed)

    @Test(
        "version intersection is fail-closed on garbage/empty and matches on a supported line",
        arguments: [
            ("awesomux-bridge-v1", true),
            ("future-v2", false),
            ("!!garbage??", false),
            ("", false),
            ("   \n   ", false),
            ("  awesomux-bridge-v1  \nfuture-v2", true),
        ]
    )
    func versionIntersection(output: String, compatible: Bool) {
        let result = BridgeDoctorSignals.compatibleProtocols(
            helperVersionOutput: output,
            appSupported: ["awesomux-bridge-v1"]
        )
        #expect(result.isEmpty == !compatible)
    }

    // MARK: - Pure: self-check exit-code mapping

    @Test(
        "self-check exit code maps to custody + round-trip, fail-closed on unknown",
        arguments: [
            (Int32(0), true, true),
            (Int32(1), false, false), // unavailable: custody failed, round-trip can't run
            (Int32(2), true, false),  // incompatible proto: file read, no handshake
            (Int32(3), true, false),  // handshake failed
            (Int32(-1), false, false), // probe error
            (Int32(99), false, false), // unknown code
        ]
    )
    func selfCheckMapping(code: Int32, custody: Bool, roundTrip: Bool) {
        let mapped = BridgeDoctorSignals.selfCheckSignals(exitCode: code)
        #expect(mapped.custody == custody)
        #expect(mapped.roundTrip == roundTrip)
    }

    // MARK: - Pure: reverse-forward mapping

    @Test("reverse-forward mapping derives owner-only from the same stat as capability")
    func reverseForwardMapping() {
        // A thrown forward means neither signal can pass.
        var r = BridgeDoctorSignals.reverseForwardSignals(forwardThrew: true, admissionOutput: "600\n")
        #expect(r.forward == false); #expect(r.ownerOnly == false)

        // Owner-only mode: both pass.
        r = BridgeDoctorSignals.reverseForwardSignals(forwardThrew: false, admissionOutput: "600\n")
        #expect(r.forward == true); #expect(r.ownerOnly == true)

        // Bound but group-accessible: capability passes, owner-only fails.
        r = BridgeDoctorSignals.reverseForwardSignals(forwardThrew: false, admissionOutput: "660\n")
        #expect(r.forward == true); #expect(r.ownerOnly == false)

        // Empty stat (socket never bound → forwarding effectively off): both fail.
        r = BridgeDoctorSignals.reverseForwardSignals(forwardThrew: false, admissionOutput: "")
        #expect(r.forward == false); #expect(r.ownerOnly == false)

        // Non-octal garbage: not a mode → not bound → both fail.
        r = BridgeDoctorSignals.reverseForwardSignals(forwardThrew: false, admissionOutput: "nope\n")
        #expect(r.forward == false); #expect(r.ownerOnly == false)
    }

    // MARK: - Full run: ordering + independence

    @Test("a healthy target passes all six signals in a stable order")
    func healthyRunPassesAllSignalsInOrder() async {
        let log = CommandLog()
        let report = await makeSignals(log: log).run(Self.context)
        #expect(report.signals.map(\.check) == BridgeDoctorCheck.allCases)
        #expect(report.allPassed)
        #expect(report.degradationMessage == nil)
        #expect(report.asDiagnostics() == nil)
    }

    @Test("one failed probe never short-circuits its siblings")
    func failedForwardDoesNotShortCircuitSiblings() async {
        let log = CommandLog()
        let report = await makeSignals(forwardThrows: true, log: log).run(Self.context)

        // All six checks still present, in order.
        #expect(report.signals.map(\.check) == BridgeDoctorCheck.allCases)
        // Only the shared forward probe's two signals failed; the independent
        // probes (helper version, local self-check, helper self-check) still ran.
        #expect(Set(report.failures.map(\.check)) == [.reverseForward, .remoteSocketOwnerOnly])

        let cmds = await log.commands
        #expect(cmds.contains { $0.contains("--version") })
        #expect(cmds.contains { $0.contains("--self-check") })
    }

    // MARK: - Exact commands, exact-path cleanup, no glob

    @Test("the doctor runs each probe once and cleans up by exact path, never a glob")
    func exactProbeCommandsAndCleanup() async {
        let log = CommandLog()
        let remote = "/tmp/awesomux-bridge-deadbeefdeadbeef.sock"
        let local = "/tmp/awesomux-bridge-probe-cafecafecafecafe.sock"
        let signals = makeSignals(log: log, probeRemote: remote, probeLocal: local)
        _ = await signals.run(Self.context)
        let cmds = await log.commands

        // Exactly one of each probe command.
        #expect(cmds.filter { $0.contains("--version") }.count == 1)
        #expect(cmds.filter { $0.contains("-O forward") }.count == 1)
        #expect(cmds.filter { $0.contains("stat -c %a") }.count == 1)
        #expect(cmds.filter { $0.contains("-O cancel") }.count == 1)
        #expect(cmds.filter { $0.contains("rm -f") }.count == 1)
        #expect(cmds.filter { $0.contains("--self-check") }.count == 1)

        // Cleanup targets the EXACT throwaway remote socket the forward used.
        let forward = cmds.first { $0.contains("-O forward") }!
        let admission = cmds.first { $0.contains("stat -c %a") }!
        let cancel = cmds.first { $0.contains("-O cancel") }!
        let remove = cmds.first { $0.contains("rm -f") }!
        #expect(forward.contains(remote))
        #expect(admission.contains(remote))
        #expect(cancel.contains(remote))
        #expect(remove.contains(remote))

        // No glob / find anywhere — the exact minted path is the only authority.
        for command in cmds {
            #expect(!command.contains("*"), "glob found: \(command)")
            #expect(!command.contains("find "), "find found: \(command)")
        }
    }

    // MARK: - Degradation-reason mapping

    @Test("every failed check maps to its own explicit reason, surfaced via diagnostics")
    func eachFailedCheckMapsToItsReason() async {
        let log = CommandLog()
        let signals = makeSignals(
            versionThrows: true,   // helperVersion
            forwardThrows: true,   // reverseForward + remoteSocketOwnerOnly
            selfCheckExit: 1,      // stateFileCustody + roundTrip
            localCustody: false,   // localSelfCheck
            log: log
        )
        let report = await signals.run(Self.context)

        #expect(!report.allPassed)
        #expect(report.failures.count == 6)
        for signal in report.failures {
            #expect(signal.reason == signal.check.failureReason)
        }

        #expect(report.degradationMessage != nil)
        let diagnostics = report.asDiagnostics()
        #expect(diagnostics != nil)
        // The disclosure body lists each failed check title + its reason.
        #expect(diagnostics!.stderr.contains(BridgeDoctorCheck.helperVersion.title))
        #expect(diagnostics!.stderr.contains(BridgeDoctorCheck.roundTrip.failureReason))
    }

    // MARK: - Secrets never leak into any reason

    @Test("a hostile token in probe outputs and paths never reaches a reason or the disclosure")
    func secretsNeverLeakIntoReasons() async {
        let hostileToken = "s3cr3t-token-4f3ca19b"
        let log = CommandLog()
        // Hostile helper that prints a token instead of a proto, a hostile stat
        // that prints a token instead of a mode, and a token baked into the
        // state-file path — the worst case for a leak.
        let signals = makeSignals(
            versionOutput: hostileToken,
            admissionOutput: hostileToken,
            selfCheckExit: 3,
            localCustody: false,
            log: log
        )
        let context = BridgeDoctorSignals.Context(
            controlPath: "/tmp/ctl/%C",
            remote: RemoteTarget(user: "ed", host: "box"),
            helperPath: "/home/ed/.awesomux/bin/awesomux-bridge-helper",
            session: TerminalSessionID(rawValue: "abc-session")!,
            stateFilePath: "/home/ed/.awesomux/bridge/\(hostileToken).json"
        )
        let report = await signals.run(context)

        for signal in report.signals {
            #expect(!signal.reason.contains(hostileToken))
        }
        #expect(report.degradationMessage?.contains(hostileToken) != true)

        let diagnostics = report.asDiagnostics()
        #expect(diagnostics != nil)
        #expect(!diagnostics!.stderr.contains(hostileToken))
        #expect(!diagnostics!.stdout.contains(hostileToken))
        #expect(!diagnostics!.summary.contains(hostileToken))
        #expect(!diagnostics!.executablePath.contains(hostileToken))
        #expect(!diagnostics!.args.joined(separator: " ").contains(hostileToken))
    }

    // MARK: - Test double

    /// Builds a `BridgeDoctorSignals` whose seams are canned/spied. The spy exec
    /// channel classifies by substring — the same discipline the preflight
    /// harness uses — and records every assembled command.
    private func makeSignals(
        versionOutput: String = "awesomux-bridge-v1",
        versionThrows: Bool = false,
        forwardThrows: Bool = false,
        admissionOutput: String = "600\n",
        selfCheckExit: Int32 = 0,
        localCustody: Bool = true,
        log: CommandLog,
        probeRemote: String = "/tmp/awesomux-bridge-0000000000000000.sock",
        probeLocal: String = "/tmp/awesomux-bridge-probe-1111111111111111.sock"
    ) -> BridgeDoctorSignals {
        var signals = BridgeDoctorSignals()
        signals.execChannel = { command, _ in
            await log.record(command)
            if command.contains("--version") {
                if versionThrows { throw BridgeExecChannel.ExecError.spawnFailed }
                return Data(versionOutput.utf8)
            }
            if command.contains("--self-check") {
                if selfCheckExit == 0 { return Data() }
                throw BridgeExecChannel.ExecError.nonzeroExit(selfCheckExit)
            }
            if command.contains("-O forward") {
                if forwardThrows { throw BridgeExecChannel.ExecError.nonzeroExit(255) }
                return Data()
            }
            if command.contains("stat -c %a") { return Data(admissionOutput.utf8) }
            // cancel + rm are best-effort no-ops.
            return Data()
        }
        signals.localCustodyCheck = { localCustody }
        signals.probeSocketPaths = { (remote: probeRemote, local: probeLocal) }
        return signals
    }
}

private actor CommandLog {
    private(set) var commands: [String] = []
    func record(_ command: String) { commands.append(command) }
}
