import Foundation

// MARK: - CodexAppServerClient

/// Codex's authoritative hook status and enabled-state writes live in a
/// `codex app-server` stdio JSON-RPC session, not in one-shot commands (contract
/// §2.4). This is the surface the installer reads/writes through.
protocol CodexAppServerClient: Sendable {
    /// The structured status read: every discovered hook with its trust state.
    func hooksList() async throws -> [HookEntry]

    /// Non-interactive enabled-state write. The installer targets key path
    /// `hooks.state` with `mergeStrategy: .upsert` and `reloadUserConfig: true`.
    func configBatchWrite(_ writes: [CodexConfigWrite], reloadUserConfig: Bool) async throws

    /// Tear down the session (and any spawned `app-server` process). Spawn-per-op
    /// callers close from a `defer`, so teardown is part of the contract every
    /// conformer must honor — not a coincidence of the concrete type.
    func close()
}

// MARK: - CodexConfigWrite

/// One entry in a `config/batchWrite` request. `value` is open-ended because the
/// installer writes a nested `hooks.state` object whose shape is the provider's,
/// not ours to model statically.
struct CodexConfigWrite: Codable, Equatable, Sendable {
    var keyPath: String
    var value: JSONValue
    var mergeStrategy: MergeStrategy

    /// The contract (§2.4) drives enabled-state writes with `upsert`; the
    /// single case pins that exact wire string. Other strategies are added when a
    /// caller needs them.
    enum MergeStrategy: String, Codable, Equatable, Sendable {
        case upsert
    }
}

// MARK: - CodexAppServerError

/// Failure modes of the app-server session, kept distinct so the caller can
/// degrade rather than crash. `appServerUnavailable` and `methodNotFound` are the
/// two version-skew signals (contract §4 #3): an older Codex may lack the
/// `app-server` subcommand entirely, or run it without the `hooks/list` /
/// `config/batchWrite` methods.
enum CodexAppServerError: Error, Equatable, Sendable {
    /// The `codex app-server` process could not be started (missing binary,
    /// subcommand absent on this version).
    case appServerUnavailable(reason: String)
    /// The server answered with JSON-RPC "method not found" (-32601): the RPC is
    /// missing on this Codex version. The caller degrades to coarse status.
    case methodNotFound(method: String)
    /// The server answered with some other JSON-RPC error.
    case rpcError(code: Int, message: String)
    /// The transport reached EOF before the matching response arrived.
    case connectionClosed
    /// The server accepted the request but produced no matching response before
    /// the deadline. A wedged or silent app-server that never replies and never
    /// closes its stdout is the §4 "no crash/hang" case: the caller degrades
    /// instead of blocking the actor — and the whole client — forever.
    case requestTimedOut(method: String)
    /// A response framed as JSON-RPC could not be decoded into the expected shape.
    case malformedResponse(String)
}

// MARK: - CodexAppServerTransport

/// Byte-framing channel under the JSON-RPC client. Splitting it out lets the
/// framing and id-correlation logic be exercised against an in-memory transport
/// with no real `codex app-server` process. Messages are exchanged as complete,
/// unframed JSON payloads; the conforming transport owns the wire framing
/// (newline delimiting for the stdio implementation).
protocol CodexAppServerTransport: AnyObject, Sendable {
    /// Send one JSON-RPC message (a single serialized object, no trailing frame).
    func send(_ message: Data) async throws
    /// Receive the next JSON-RPC message, or `nil` at EOF.
    func receive() async throws -> Data?
    /// Tear down the underlying channel (and any spawned process).
    func close()
}
