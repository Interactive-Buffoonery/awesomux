import Foundation

// MARK: - ProcessCodexAppServerClient

/// JSON-RPC client over a stdio transport. The actor serializes access, so there
/// is at most one in-flight request; responses are correlated by a monotonically
/// increasing id, and unrelated messages (notifications, stale ids) are skipped.
actor ProcessCodexAppServerClient: CodexAppServerClient {
    private let transport: CodexAppServerTransport
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()
    private let requestTimeout: Duration
    private let clientInfo: ClientInfo
    private var nextID = 1
    private var didInitialize = false

    init(
        transport: CodexAppServerTransport,
        requestTimeout: Duration = .seconds(30),
        clientInfo: ClientInfo = .awesoMux,
        assumeInitialized: Bool = false
    ) {
        self.transport = transport
        self.requestTimeout = requestTimeout
        self.clientInfo = clientInfo
        self.didInitialize = assumeInitialized
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        self.encoder = encoder
    }

    /// Identifies the client in the required `initialize` handshake. Codex routes
    /// this to its compliance-logs platform and rejects the request without it.
    struct ClientInfo: Encodable, Sendable {
        var name: String
        var title: String
        var version: String

        static let awesoMux = ClientInfo(
            name: "awesomux",
            title: "awesoMux",
            version: (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
        )
    }

    /// Spawns `codex app-server` with `CODEX_HOME` threaded in and wraps it.
    /// Throws `CodexAppServerError.appServerUnavailable` if the process cannot be
    /// started — the CLI-absent / subcommand-absent version-skew signal.
    static func spawning(
        codexExecutable: String,
        codexHome: String,
        searchPath: String = ProcessCommandRunner.defaultToolPath,
        requestTimeout: Duration = .seconds(30)
    ) throws -> ProcessCodexAppServerClient {
        let transport = try ProcessCodexAppServerTransport(
            executable: codexExecutable,
            codexHome: codexHome,
            defaultPath: searchPath
        )
        return ProcessCodexAppServerClient(transport: transport, requestTimeout: requestTimeout)
    }

    func hooksList() async throws -> [HookEntry] {
        try await ensureInitialized()
        let result = try await request(method: "hooks/list", params: JSONValue.object([:]))
        do {
            // Re-encode the correlated `JSONValue` and decode the typed result:
            // this encode→decode is the idiomatic JSONValue→Decodable bridge in
            // Foundation. Decoding "directly" would mean either a hand-written
            // JSONValue Decoder or threading a result type through the raced,
            // timeout-guarded `request`/`correlate` plumbing — more code and new
            // bug surface for a hot path that is already off the spawn-per-op
            // critical path. The bounce stays intentionally.
            let data = try encoder.encode(result)
            return try decoder.decode(HooksListResult.self, from: data).hooks
        } catch {
            throw CodexAppServerError.malformedResponse(
                "hooks/list result: \(error.localizedDescription)"
            )
        }
    }

    func configBatchWrite(_ writes: [CodexConfigWrite], reloadUserConfig: Bool) async throws {
        try await ensureInitialized()
        let params = BatchWriteParams(writes: writes, reloadUserConfig: reloadUserConfig)
        _ = try await request(method: "config/batchWrite", params: params)
    }

    /// The Codex app-server is a JSON-RPC server in the MCP/LSP family: it rejects
    /// every method until an `initialize` request (carrying `clientInfo`) has been
    /// acknowledged. Both public RPCs run over the same session, so the handshake
    /// lives here — performed once, lazily — rather than at each call site. Codex
    /// does not require the follow-up `initialized` notification; the response to
    /// `initialize` alone unlocks the session.
    ///
    /// The `guard` is not reentrancy-hardened: callers spawn a fresh client per op
    /// and issue a single `hooksList`/`configBatchWrite` before `close()`, so two
    /// concurrent first-calls racing the `await` cannot occur in practice.
    private func ensureInitialized() async throws {
        guard !didInitialize else { return }
        _ = try await request(method: "initialize", params: InitializeParams(clientInfo: clientInfo))
        didInitialize = true
    }

    /// Tearing down only forwards to the transport (a `let`, `Sendable`, with a
    /// synchronous `close()`), so it needs no actor isolation — letting a
    /// spawn-per-op caller close the session from a `defer` without awaiting.
    nonisolated func close() {
        transport.close()
    }

    deinit {
        transport.close()
    }

    // MARK: - JSON-RPC plumbing

    private func request<P: Encodable>(method: String, params: P) async throws -> JSONValue {
        let id = nextID
        nextID += 1

        let envelope = RequestEnvelope(id: id, method: method, params: params)
        let data = try encoder.encode(envelope)
        try await transport.send(data)

        // Bound the wait: a server that accepts the request but never replies and
        // never closes its stdout would otherwise park the receive loop forever,
        // and the single-in-flight actor would wedge the whole client. Racing the
        // correlation loop against a deadline keeps the §4 version-skew contract
        // ("no crash/hang") — the caller gets `requestTimedOut` and degrades.
        // The losing child is cancelled on exit; the transport's own `close()`
        // unblocks any read still parked in the real stdio transport.
        let timeout = requestTimeout
        // Shared deadline flag: closing the transport to unblock a parked read
        // makes `correlate` observe EOF (`connectionClosed`) at almost the same
        // instant the deadline child throws. To keep the §4 contract surfacing
        // `requestTimedOut` deterministically — rather than racing on which child
        // reaches `next()` first — the deadline child sets this before closing, and
        // a `connectionClosed` seen while it is set is reinterpreted as the timeout.
        let timedOut = OneShotFlag()
        // Closing the transport is the only thing that unblocks a `receive()`
        // parked in the real stdio transport's non-cancellable `availableData`
        // read. The deadline child does that on timeout — but external
        // cancellation (e.g. the settings pane closing) preempts that child's
        // `Task.sleep` before it can close, leaving `correlate` parked and the
        // task group unable to return, which leaks the app-server process and
        // wedges the op. The cancellation handler closes the transport so the
        // read unwinds and the group can drain.
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: JSONValue.self) { group in
                group.addTask { [transport] in
                    do {
                        return try await Self.correlate(id: id, method: method, transport: transport)
                    } catch CodexAppServerError.connectionClosed where timedOut.isSet {
                        throw CodexAppServerError.requestTimedOut(method: method)
                    }
                }
                group.addTask { [transport] in
                    try await Task.sleep(for: timeout)
                    timedOut.set()
                    transport.close()
                    throw CodexAppServerError.requestTimedOut(method: method)
                }
                defer { group.cancelAll() }
                // The first child to finish wins; `next()` rethrows its error.
                return try await group.next()!
            }
        } onCancel: {
            transport.close()
        }
    }

    /// Reads framed responses until the one matching `id` arrives, skipping
    /// malformed lines, notifications (no id), and responses to other ids.
    /// Runs in a detached child so it can be raced against the request deadline;
    /// uses a fresh decoder to avoid touching actor-isolated state off-actor.
    private static func correlate(
        id: Int,
        method: String,
        transport: CodexAppServerTransport
    ) async throws -> JSONValue {
        let decoder = JSONDecoder()
        while true {
            try Task.checkCancellation()
            guard let line = try await transport.receive() else {
                throw CodexAppServerError.connectionClosed
            }
            guard let response = try? decoder.decode(ResponseEnvelope.self, from: line),
                  response.id == id else {
                continue
            }
            if let error = response.error {
                if error.code == -32601 {
                    throw CodexAppServerError.methodNotFound(method: method)
                }
                throw CodexAppServerError.rpcError(code: error.code, message: error.message)
            }
            return response.result ?? .null
        }
    }
}

// MARK: - Wire envelopes

private struct RequestEnvelope<P: Encodable>: Encodable {
    let jsonrpc = "2.0"
    let id: Int
    let method: String
    let params: P
}

private struct ResponseEnvelope: Decodable {
    let id: Int?
    let result: JSONValue?
    let error: RPCError?

    struct RPCError: Decodable {
        let code: Int
        let message: String
    }
}

private struct InitializeParams: Encodable {
    let clientInfo: ProcessCodexAppServerClient.ClientInfo
}

private struct BatchWriteParams: Encodable {
    let writes: [CodexConfigWrite]
    let reloadUserConfig: Bool

    // The live app-server `config/batchWrite` spec names the edit list `edits`,
    // not `writes`; a `writes` key is silently ignored by a real binary, so the
    // enable/disable RPC would no-op. The Swift-facing param name stays `writes`
    // for call-site readability; only the wire key is mapped.
    enum CodingKeys: String, CodingKey {
        case writes = "edits"
        case reloadUserConfig
    }
}

/// The `hooks/list` result wraps its hooks in a per-working-directory array:
/// `result.data[].hooks`. Each `data` entry also carries `warnings`/`errors` that
/// are environmental (e.g. an unrelated plugin's malformed config in this cwd),
/// not properties of any one hook, so they are intentionally not surfaced onto
/// `HookEntry` and do not gate awesoMux's own card status.
private struct HooksListResult: Decodable {
    let data: [CwdHooks]

    struct CwdHooks: Decodable {
        let hooks: [HookEntry]

        // A per-cwd entry with no discovered hooks may omit `hooks` entirely;
        // treat an absent array as empty rather than letting the whole list fail
        // to decode (which would mask real status behind `malformedResponse`).
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            hooks = try container.decodeIfPresent([HookEntry].self, forKey: .hooks) ?? []
        }

        private enum CodingKeys: String, CodingKey {
            case hooks
        }
    }

    var hooks: [HookEntry] {
        data.flatMap(\.hooks).sorted {
            if $0.sourcePath != $1.sourcePath {
                return $0.sourcePath < $1.sourcePath
            }
            if $0.eventName != $1.eventName {
                return $0.eventName < $1.eventName
            }
            return $0.key < $1.key
        }
    }
}
