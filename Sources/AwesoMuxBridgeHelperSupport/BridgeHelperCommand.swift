import AwesoMuxCore
import Foundation

/// Entry-point logic for `awesoMuxBridgeHelper`, kept out of main.swift so
/// argv parsing is unit-testable — mirrors `AgentHookCommand` in
/// `AwesoMuxAgentHookSupport`.
///
public enum BridgeHelperCommand {
    /// Protocols this helper build understands. `--version` prints each on
    /// its own line. A list, not a single string, so a
    /// future protocol bump can advertise both the old and new version
    /// during rollout.
    public static let supportedProtocols = ["awesomux-bridge-v1"]

    /// `--self-check` exit codes, consumed by the doctor's state-file-custody
    /// and round-trip signals (INT-698 F1). Ordered by the stage that failed so
    /// one probe reports both signals: `unavailable` fails custody; the later
    /// codes mean custody passed but the round-trip did not.
    public enum SelfCheckExit {
        public static let unavailable: Int32 = 1
        public static let incompatibleProtocol: Int32 = 2
        public static let handshakeFailed: Int32 = 3
    }

    public static func run(
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: @escaping () -> Date = Date.init,
        readState: (String) -> BridgeStateFile? = { BridgeStateFileCustody.read(path: $0) },
        connect: (BridgeStateFile, String) throws -> HelperConnection = { state, session in
            try HelperConnection.connect(state: state, session: session)
        },
        output: (String) -> Void = writeStandardOutput,
        errorOutput: (String) -> Void = writeStandardError
    ) -> Int32 {
        if arguments == ["--version"] {
            supportedProtocols.forEach(output)
            return 0
        }

        if arguments == ["--self-check"] {
            // Distinct exit codes so a doctor consuming this over an
            // stderr-discarding exec channel can still tell the state-file
            // custody signal apart from the round-trip signal (INT-698 F1). The
            // terse stderr line stays for a human running the helper by hand,
            // but is never the machine-readable contract.
            guard let context = loadContext(environment: environment, readState: readState) else {
                errorOutput("awesoMuxBridgeHelper: bridge unavailable")
                return SelfCheckExit.unavailable
            }
            guard supportedProtocols.contains(context.state.proto) else {
                errorOutput("awesoMuxBridgeHelper: incompatible protocol")
                return SelfCheckExit.incompatibleProtocol
            }
            do {
                let connection = try connect(context.state, context.session)
                try connection.handshake(proto: context.state.proto, helper: helperVersion, wallNow: now())
                return 0
            } catch {
                errorOutput("awesoMuxBridgeHelper: handshake failed")
                return SelfCheckExit.handshakeFailed
            }
        }

        if arguments.count == 2, arguments[0] == "--emit" {
            guard let context = loadContext(environment: environment, readState: readState),
                  supportedProtocols.contains(context.state.proto),
                  let contents = try? String(contentsOfFile: arguments[1], encoding: .utf8)
            else {
                return 0
            }
            do {
                let connection = try connect(context.state, context.session)
                try connection.handshake(proto: context.state.proto, helper: helperVersion, wallNow: now())
                let envelopes = contents.split(whereSeparator: \.isNewline).compactMap {
                    BridgeFixtureEvent.parse(
                        line: String($0), token: context.state.token, session: context.session, now: now()
                    )
                }
                try run(envelopes: envelopes, on: connection, context: context, now: now)
            } catch {
                // Provider hooks and fixture smoke both inherit the bridge's
                // fail-silent availability contract.
            }
            return 0
        }

        // No args (or any other unrecognized flag) is a silent no-op
        // exit — this is a per-invocation helper stub; the connection runtime
        // (INT-698 task B2) is what gives a bare invocation real work.
        return 0
    }

    private static let helperVersion = "awesomux-remote-helper/1.0.0"

    private struct Context {
        let state: BridgeStateFile
        let session: String
    }

    private static func loadContext(
        environment: [String: String],
        readState: (String) -> BridgeStateFile?
    ) -> Context? {
        guard let path = environment["AWESOMUX_BRIDGE_STATE"], path.hasPrefix("/"),
              let session = environment["AWESOMUX_BRIDGE_SESSION"], !session.isEmpty,
              let state = readState(path)
        else {
            return nil
        }
        return Context(state: state, session: session)
    }

    private static func run(
        envelopes: [BridgeEnvelope],
        on connection: HelperConnection,
        context: Context,
        now: @escaping () -> Date
    ) throws {
        var runtime = HelperPermissionRuntime(token: context.state.token, session: context.session)
        var requestDeadlines: [String: Date] = [:]

        for envelope in envelopes {
            guard case .permissionRequest(let request) = envelope.message else {
                // A fixture cannot turn the helper into an app-side sender.
                if case .permissionDecision = envelope.message { continue }
                try connection.send(envelope)
                continue
            }

            switch runtime.admit(envelope: envelope, now: now()) {
            case .overflow(_, let resolved):
                try connection.send(resolved)
            case .rejected:
                continue
            case .admitted:
                requestDeadlines[envelope.id] = Date(timeIntervalSince1970: request.expiresAt)
                try connection.send(envelope)
            }
        }

        while runtime.pendingCount > 0 {
            let liveDeadlines = requestDeadlines.filter { runtime.peek(id: $0.key) != nil }
            guard let wallDeadline = liveDeadlines.values.min() else { break }
            let monotonicDeadline = HelperConnection.defaultMonotonicNow().addingTimeInterval(
                max(0, wallDeadline.timeIntervalSince(now()))
            )

            do {
                while let decision = try connection.readPermissionDecision(deadline: monotonicDeadline) {
                    guard let outcome = runtime.acceptDecision(decision, now: now()) else { continue }
                    if case .expired = outcome {
                        try connection.send(expiredEnvelope(
                            requestID: decisionID(decision) ?? "", context: context, now: now()
                        ))
                    }
                    break
                }
            } catch HelperConnection.ConnectionError.timedOut {
                for resolved in runtime.sweepExpired(now: wallDeadline) { try connection.send(resolved) }
            } catch {
                _ = runtime.connectionLost()
                throw error
            }
        }
    }

    private static func decisionID(_ envelope: BridgeEnvelope) -> String? {
        guard case .permissionDecision(let decision) = envelope.message else { return nil }
        return decision.inReplyTo
    }

    private static func expiredEnvelope(requestID: String, context: Context, now: Date) -> BridgeEnvelope {
        BridgeEnvelope(
            token: context.state.token, session: context.session, id: UUID().uuidString,
            ts: now.timeIntervalSince1970,
            message: .permissionResolved(PermissionResolved(inReplyTo: requestID, reason: .expired))
        )
    }

    public static func writeStandardOutput(_ message: String) {
        writeLine(message, to: .standardOutput)
    }

    public static func writeStandardError(_ message: String) {
        writeLine(message, to: .standardError)
    }

    private static func writeLine(_ message: String, to fileHandle: FileHandle) {
        var data = Data(message.utf8)
        data.append(0x0a)
        fileHandle.write(data)
    }
}
