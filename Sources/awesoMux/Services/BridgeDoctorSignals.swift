import AwesoMuxCore
import Foundation

// MARK: - BridgeDoctorCheck

/// The named bridge health checks the doctor reports.
///
/// These are diagnostic signals only: one pass/fail plus a display-safe reason
/// per check. They do not install or repair the optional remote helper.
enum BridgeDoctorCheck: Sendable, Equatable, CaseIterable {
    /// The remote helper is installed and advertises a protocol this app build
    /// supports (`--version` intersected against the app's supported set).
    case helperVersion
    /// SSH Unix-socket reverse forwarding works, probed empirically.
    case reverseForward
    /// The reverse-forwarded remote socket is owner-only (no group/world bits).
    case remoteSocketOwnerOnly
    /// The app-side half of the custody split: the local listener directory is
    /// owner-only (`0700`) and its socket is owner-only.
    case localSelfCheck
    /// The remote helper can read the bridge state file under its custody rules
    /// (the remote half of the split), read from the helper's `--self-check`.
    case stateFileCustody
    /// A full `hello`/`hello-ack` handshake completes through the forward.
    case roundTrip

    /// Short human title, used as the disclosure line label and never carrying
    /// anything host-specific.
    var title: String {
        switch self {
        case .helperVersion:
            String(localized: "Remote helper", comment: "Bridge doctor check title")
        case .reverseForward:
            String(localized: "SSH forwarding", comment: "Bridge doctor check title")
        case .remoteSocketOwnerOnly:
            String(localized: "Remote socket permissions", comment: "Bridge doctor check title")
        case .localSelfCheck:
            String(localized: "Local listener permissions", comment: "Bridge doctor check title")
        case .stateFileCustody:
            String(localized: "State file custody", comment: "Bridge doctor check title")
        case .roundTrip:
            String(localized: "Bridge handshake", comment: "Bridge doctor check title")
        }
    }

    /// The explicit, display-safe failure reason. Fixed human phrases only — no
    /// token, socket path, or state-file contents ever appears, so a screenshot
    /// of the doctor leaks nothing the plugin-card diagnostics wouldn't.
    var failureReason: String {
        switch self {
        case .helperVersion:
            String(localized: "The awesoMux remote helper is missing or reports an incompatible protocol version.", comment: "Bridge doctor failure reason")
        case .reverseForward:
            String(localized: "SSH Unix-socket forwarding is disabled on the remote host.", comment: "Bridge doctor failure reason")
        case .remoteSocketOwnerOnly:
            String(localized: "The remote bridge socket is group- or world-accessible.", comment: "Bridge doctor failure reason")
        case .localSelfCheck:
            String(localized: "awesoMux could not create an owner-only local listener.", comment: "Bridge doctor failure reason")
        case .stateFileCustody:
            String(localized: "The remote helper cannot read the bridge state file under its custody rules.", comment: "Bridge doctor failure reason")
        case .roundTrip:
            String(localized: "The bridge handshake did not complete.", comment: "Bridge doctor failure reason")
        }
    }
}

// MARK: - BridgeDoctorSignal

/// One check's outcome: pass/fail plus a display-safe reason.
struct BridgeDoctorSignal: Sendable, Equatable {
    let check: BridgeDoctorCheck
    let passed: Bool
    /// Display-safe. On failure this is `check.failureReason`; on success it is
    /// the check title. Never interpolates a token, socket path, or state-file
    /// contents.
    let reason: String

    static func pass(_ check: BridgeDoctorCheck) -> BridgeDoctorSignal {
        BridgeDoctorSignal(check: check, passed: true, reason: check.title)
    }

    static func fail(_ check: BridgeDoctorCheck) -> BridgeDoctorSignal {
        BridgeDoctorSignal(check: check, passed: false, reason: check.failureReason)
    }
}

// MARK: - BridgeDoctorReport

/// The full set of six signals from one doctor run, plus the surfacing helpers
/// that fold into the *existing* `AgentPluginDiagnostics` lane rather than a
/// parallel doctor surface (contributor ruling).
struct BridgeDoctorReport: Sendable, Equatable {
    /// The remote helper path the probes targeted. Surfaced verbatim as the
    /// diagnostics `executablePath` (the local-home `~` redaction anchors on the
    /// LOCAL home, so a remote `/home/<user>/…` path is shown as-is) — the
    /// remote username is in-scope to show, exactly as the plugin cards show an
    /// executable path. Not a secret.
    let helperPath: String
    let signals: [BridgeDoctorSignal]

    var allPassed: Bool { signals.allSatisfy(\.passed) }
    var failures: [BridgeDoctorSignal] { signals.filter { !$0.passed } }

    /// The explicit, localized degradation line the spec mandates ("remote
    /// terminal works; rich agent features off") — nil when the bridge is fully
    /// healthy. Never silent (spec: "Degradation is explicit, never silent").
    var degradationMessage: String? {
        guard !allPassed else { return nil }
        return String(
            localized: "Remote terminal works; rich agent features are off.",
            comment: "Bridge doctor degradation banner when the bridge is down"
        )
    }

    /// Surfaces the failing checks through the SAME `AgentPluginDiagnostics`
    /// disclosure the plugin cards use — the "extend the lane, no parallel
    /// surface" ruling. Nil when everything passed (no disclosure to show).
    /// A caller can place the returned value in the existing
    /// `diagnosticsDisclosure`, listing each failed check and its reason with
    /// the degradation line as summary.
    func asDiagnostics() -> AgentPluginDiagnostics? {
        let failed = failures
        guard !failed.isEmpty else { return nil }
        // One line per failed check. All reasons are fixed phrases, so nothing
        // secret can reach the redaction path here — but it still runs, matching
        // the plugin-card contract byte for byte.
        let body = failed.map { "\($0.check.title): \($0.reason)" }.joined(separator: "\n")
        return AgentPluginDiagnostics(
            executablePath: helperPath,
            args: ["--version", "--self-check"],
            exitCode: nil,
            rawStdout: "",
            rawStderr: body,
            summary: degradationMessage ?? ""
        )
    }
}

// MARK: - BridgeDoctorSignals

/// Runs the six bridge health signals against a managed remote target.
///
/// Every live probe is a seam-injected closure with a live default (the D2
/// pattern), so unit tests drive the whole thing without touching ssh or
/// binding a socket; the live path is exercised in the manual smoke.
///
/// **Check independence / ordering.** All six signals always run — no probe
/// short-circuits a sibling. The couplings are genuine shared probes, not
/// short-circuits:
///
///  - `helperVersion` — independent (one `--version` over ssh).
///  - `reverseForward` + `remoteSocketOwnerOnly` — one throwaway `-O forward`
///    probe; owner-only is read from the same `stat` as forward capability.
///    Independent of the helper.
///  - `localSelfCheck` — independent, local-only (no ssh).
///  - `stateFileCustody` + `roundTrip` — one helper `--self-check`; both derive
///    from its exit code. `roundTrip` *logically* depends on `helperVersion`
///    (helper present) and `reverseForward` (a forward to handshake through),
///    but is still probed independently: a failing helper or forward surfaces
///    as a failing `--self-check` exit code, never a skipped check.
struct BridgeDoctorSignals: Sendable {
    /// What one doctor run needs to know: the shared master, the remote target,
    /// the installed helper path, and the currently-published state file /
    /// session the `--self-check` should read.
    struct Context: Sendable {
        let controlPath: String
        let remote: RemoteTarget
        let helperPath: String
        let session: TerminalSessionID
        /// The live attach's published state-file path; the `--self-check` env
        /// prefix points the helper at it.
        let stateFilePath: String
    }

    // Closures with live defaults, not protocols — one real implementation each.
    typealias ExecChannel = @Sendable (_ command: String, _ stdin: Data?) async throws -> Data
    typealias LocalCustodyCheck = @Sendable () async -> Bool
    typealias ProbeSocketPaths = @Sendable () -> (remote: String, local: String)?

    var execChannel: ExecChannel = BridgeDoctorSignals.liveExecChannel
    var localCustodyCheck: LocalCustodyCheck = BridgeDoctorSignals.liveLocalCustodyCheck
    var probeSocketPaths: ProbeSocketPaths = BridgeDoctorSignals.liveProbeSocketPaths
    var appSupportedProtocols: Set<String> = Set(BridgeConnectionSupervisor.supportedProtocols)

    func run(_ context: Context) async -> BridgeDoctorReport {
        var signals: [BridgeDoctorSignal] = []
        signals.append(await helperVersionSignal(context))
        let reverse = await reverseForwardProbe(context)
        signals.append(reverse.forward)
        signals.append(reverse.ownerOnly)
        signals.append(await localSelfCheckSignal())
        let selfCheck = await selfCheckProbe(context)
        signals.append(selfCheck.custody)
        signals.append(selfCheck.roundTrip)
        return BridgeDoctorReport(helperPath: context.helperPath, signals: signals)
    }

    // MARK: - Pure interpretation (unit-tested without ssh)

    /// Intersects the helper's `--version` output (one protocol per line)
    /// against the app's supported set. Empty result ⇒ incompatible. Garbage or
    /// empty output ⇒ empty intersection ⇒ fail-closed, never accepted.
    static func compatibleProtocols(
        helperVersionOutput: String,
        appSupported: Set<String>
    ) -> Set<String> {
        let advertised = helperVersionOutput
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return appSupported.intersection(advertised)
    }

    /// Maps the throwaway forward probe's outcome to the two signals. The
    /// admission command only prints a mode when the remote socket exists AND is
    /// owned by the session user, so any parseable octal line proves the forward
    /// registered (capability); the mode bits then refine owner-only.
    static func reverseForwardSignals(
        forwardThrew: Bool,
        admissionOutput: String
    ) -> (forward: Bool, ownerOnly: Bool) {
        if forwardThrew { return (false, false) }
        let bound = admissionOutput
            .split(whereSeparator: \.isNewline)
            .contains { Int($0.trimmingCharacters(in: .whitespaces), radix: 8) != nil }
        guard bound else { return (false, false) }
        return (true, AmxBackend.bridgeAdmissionPassed(statOutput: admissionOutput))
    }

    /// Maps the helper `--self-check` exit code to the custody + round-trip
    /// signals. The exit-code contract is duplicated by value from
    /// `BridgeHelperCommand.SelfCheckExit` — the app and the helper are separate
    /// targets with no shared dependency, so the exit code is the wire contract
    /// (same discipline as the duplicated `supportedProtocols` lists).
    static func selfCheckSignals(exitCode: Int32) -> (custody: Bool, roundTrip: Bool) {
        switch exitCode {
        case 0:
            return (true, true)
        case 1: // unavailable — state-file custody failed, so round-trip cannot run
            return (false, false)
        case 2, 3: // incompatible proto / handshake failed — file read, handshake did not complete
            return (true, false)
        default: // probe error (timeout/spawn/cancel) or unknown code → fail-closed both
            return (false, false)
        }
    }

    // MARK: - Probes

    private func helperVersionSignal(_ context: Context) async -> BridgeDoctorSignal {
        let command = AmxBackend.bridgeHelperVersionCommand(
            controlPath: context.controlPath,
            remote: context.remote,
            helperPath: context.helperPath
        )
        guard let data = try? await execChannel(command, nil) else {
            // Helper missing, or ssh failed → treat as unavailable (fail-closed).
            return .fail(.helperVersion)
        }
        let compatible = Self.compatibleProtocols(
            helperVersionOutput: String(decoding: data, as: UTF8.self),
            appSupported: appSupportedProtocols
        )
        return compatible.isEmpty ? .fail(.helperVersion) : .pass(.helperVersion)
    }

    private func reverseForwardProbe(
        _ context: Context
    ) async -> (forward: BridgeDoctorSignal, ownerOnly: BridgeDoctorSignal) {
        guard let paths = probeSocketPaths() else {
            return (.fail(.reverseForward), .fail(.remoteSocketOwnerOnly))
        }

        var forwardThrew = false
        do {
            _ = try await execChannel(
                AmxBackend.bridgeReverseForwardCommand(
                    controlPath: context.controlPath,
                    remote: context.remote,
                    remoteSocketPath: paths.remote,
                    localSocketPath: paths.local
                ),
                nil
            )
        } catch {
            forwardThrew = true
        }

        var admissionOutput = ""
        if !forwardThrew,
           let data = try? await execChannel(
               AmxBackend.bridgeRemoteSocketAdmissionCommand(
                   controlPath: context.controlPath,
                   remote: context.remote,
                   remoteSocketPath: paths.remote
               ),
               nil
           ) {
            admissionOutput = String(decoding: data, as: UTF8.self)
        }

        // Cleanup ALWAYS, by the EXACT throwaway path — cancel the forward, then
        // remove the socket. Best-effort no-ops if the forward never registered
        // (spec finding 16). Never a glob: the exact minted path is the only
        // deletion authority, exactly as the attach ledger's teardown.
        //
        // Best-effort, matching `BridgeAttachPreflight.rollbackNew`. If
        // this run is cancelled after the forward registered, `BridgeExecChannel`
        // bails on `Task.isCancelled` and the throwaway forward+socket survive —
        // an INERT orphan (the forward points at a dead local path, nothing can
        // misdeliver), which the spec designates a doctor-repair concern, not a
        // rollback one. Upgrade to a cancellation-shielded teardown only if these
        // probe orphans measurably accumulate.
        _ = try? await execChannel(
            AmxBackend.bridgeReverseForwardCancelCommand(
                controlPath: context.controlPath,
                remote: context.remote,
                remoteSocketPath: paths.remote,
                localSocketPath: paths.local
            ),
            nil
        )
        _ = try? await execChannel(
            AmxBackend.bridgeRemoteSocketRemoveCommand(
                controlPath: context.controlPath,
                remote: context.remote,
                remoteSocketPath: paths.remote
            ),
            nil
        )

        let result = Self.reverseForwardSignals(
            forwardThrew: forwardThrew,
            admissionOutput: admissionOutput
        )
        return (
            result.forward ? .pass(.reverseForward) : .fail(.reverseForward),
            result.ownerOnly ? .pass(.remoteSocketOwnerOnly) : .fail(.remoteSocketOwnerOnly)
        )
    }

    private func localSelfCheckSignal() async -> BridgeDoctorSignal {
        await localCustodyCheck() ? .pass(.localSelfCheck) : .fail(.localSelfCheck)
    }

    /// Runs the helper `--self-check` and derives the custody + round-trip
    /// signals from its exit code alone (stderr is discarded by the exec
    /// channel, so nothing sensitive is ever read).
    ///
    /// ⚠️ Live-path caveat: `--self-check` opens a
    /// real handshake through the forward, and a new `hello` atomically replaces
    /// the prior connection (spec "Connection ownership"). Running this against a
    /// live agent's listener would briefly displace that connection. A caller
    /// must run the round-trip only when that is safe (no live agent connection)
    /// or bind a dedicated probe listener+forward. F1 supplies the classification
    /// only.
    private func selfCheckProbe(
        _ context: Context
    ) async -> (custody: BridgeDoctorSignal, roundTrip: BridgeDoctorSignal) {
        let command = AmxBackend.bridgeHelperSelfCheckCommand(
            controlPath: context.controlPath,
            remote: context.remote,
            helperPath: context.helperPath,
            stateFilePath: context.stateFilePath,
            session: context.session
        )
        let exitCode: Int32
        do {
            _ = try await execChannel(command, nil)
            exitCode = 0
        } catch let BridgeExecChannel.ExecError.nonzeroExit(code) {
            exitCode = code
        } catch {
            exitCode = -1 // timeout / spawn / cancel — probe could not complete
        }

        let mapped = Self.selfCheckSignals(exitCode: exitCode)
        return (
            mapped.custody ? .pass(.stateFileCustody) : .fail(.stateFileCustody),
            mapped.roundTrip ? .pass(.roundTrip) : .fail(.roundTrip)
        )
    }

    // MARK: - Live seam defaults (exercised only in the manual smoke)

    private static let liveExecChannel: ExecChannel = { command, stdin in
        try await BridgeExecChannel.run(command: command, stdin: stdin)
    }

    /// Binds a throwaway listener through the SAME primitive every real bridge
    /// listener uses; its init already enforces dir `0700` + owner-only `0600`
    /// socket and throws otherwise, so a clean bind IS the app-side custody pass.
    private static let liveLocalCustodyCheck: LocalCustodyCheck = {
        guard let actor = try? BridgeConnectionActor(
            expectedToken: "doctor-probe",
            expectedSession: "doctor-probe"
        ) else {
            return false
        }
        await actor.shutdown()
        return true
    }

    /// Synthesizes throwaway socket paths in the same `/tmp/awesomux-bridge-…`
    /// shape the attach uses. The probe only establishes the forward and stats
    /// the *remote* socket, so the local path is never bound here — no dir to
    /// create, nothing to leak.
    private static let liveProbeSocketPaths: ProbeSocketPaths = {
        let remoteHex = String(format: "%016llx", UInt64.random(in: .min ... .max))
        let localHex = String(format: "%016llx", UInt64.random(in: .min ... .max))
        return (
            remote: "/tmp/awesomux-bridge-\(remoteHex).sock",
            local: "/tmp/awesomux-bridge-probe-\(localHex).sock"
        )
    }
}
