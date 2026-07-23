import AwesoMuxBridgeProtocol
import AwesoMuxCore
import Foundation

/// Per-attach descriptor for the `awesomux-bridge-v1` transport: the
/// token/generation/paths minted or resolved once per attach sequence.
///
/// `localSocketPath` is a passthrough, not minted here: binding the local
/// listener is a live side effect owned by `BridgeConnectionActor` (via
/// `BridgeListenerDirectory`). This type only gathers it alongside the rest
/// of the attach's identity so `AmxBackend`'s string-assembly functions have
/// one value to build commands from instead of five loose parameters.
struct BridgeChannel: Sendable, Equatable {
    let token: String
    let gen: Int
    let localSocketPath: String
    let remoteSocketPath: String
    let stateFilePath: String
    let session: TerminalSessionID

    /// macOS `sockaddr_un.sun_path` budget `AmxBackend.sshControlPath()`
    /// guards for the ControlMaster socket. The reverse-forwarded bridge
    /// socket is bound by the remote `sshd` and answers to the same limit
    /// (spec: "Setup and the remote socket path").
    static let sockaddrUnPathLimit = AmxBackend.sockaddrUnPathLimit

    /// Mints a fresh per-attach channel: a crypto-random token (same
    /// RNG/shape as `AmxBackend.makeStatusChannel`'s forgery token) and an
    /// unpredictable remote socket path (`/tmp/awesomux-bridge-<16 hex>.sock`,
    /// spec: "Setup and the remote socket path" — the 16-hex form is
    /// ~42 bytes, well under the 104-byte budget).
    ///
    /// `localSocketPath` and `remoteHome` are supplied by the caller because
    /// producing them is a live side effect this pure constructor does not
    /// perform: binding a listener, and capturing `$HOME` over the exec
    /// channel (spec: "the one-time $HOME capture", see
    /// `AmxBackend.bridgeHomeResolutionCommand`).
    ///
    /// `previousGeneration` has no default on purpose: `gen`'s whole job is
    /// same-epoch concurrent-write detection, and a defaulted `0` would let
    /// a careless second call site silently re-mint gen 1 forever. The
    /// serialized attach owner (D2) threads the last published value; `0` is
    /// only ever passed explicitly, for a genuinely fresh epoch.
    ///
    /// Returns nil when `remoteHome` isn't a usable absolute path — the spec
    /// mandates helpers never expand `~`, so a state file path built on a
    /// bad capture would silently name a path nothing could resolve. The
    /// scalar-safety fence matches the one `BridgeStateFile.parse` applies
    /// to its `socket` field: `remoteHome` is host-supplied text (a live
    /// `$HOME` capture), and an embedded bidi/zero-width scalar would make
    /// the path this process displays differ from the one it uses.
    static func mint(
        session: TerminalSessionID,
        previousGeneration: Int,
        localSocketPath: String,
        remoteHome: String
    ) -> BridgeChannel? {
        guard remoteHome.hasPrefix("/"),
              !remoteHome.contains("\0"),
              !MarkdownLinkIntercept.containsUnsafePathScalars(remoteHome)
        else {
            return nil
        }
        // Trailing-slash normalization so `/home/ed/` (or `/` itself, the
        // root-home edge) can't bake a `//` into the state file path — the
        // shell would still resolve it, but this exact string is what gets
        // injected as AWESOMUX_BRIDGE_STATE and compared byte-for-byte.
        var home = remoteHome
        while home.hasSuffix("/") {
            home.removeLast()
        }

        // 16 bytes = two random UInt64 values → 32 hex chars, mirroring
        // `AmxBackend.makeStatusChannel`'s forgery token exactly.
        var rng = SystemRandomNumberGenerator()
        let tokenHi = UInt64.random(in: .min ... .max, using: &rng)
        let tokenLo = UInt64.random(in: .min ... .max, using: &rng)
        let token = String(format: "%016llx%016llx", tokenHi, tokenLo)

        // 8 bytes = one random UInt64 → 16 hex chars, per the spec's literal
        // remote-socket-path example.
        let socketSuffix = String(format: "%016llx", UInt64.random(in: .min ... .max, using: &rng))
        let remoteSocketPath = "/tmp/awesomux-bridge-\(socketSuffix).sock"
        assert(
            remoteSocketPath.utf8.count < sockaddrUnPathLimit,
            "bridge remote socket path exceeds the sockaddr_un budget"
        )

        let stateFilePath = home + "/.awesomux/bridge/\(session.rawValue).json"

        return BridgeChannel(
            token: token,
            gen: previousGeneration + 1,
            localSocketPath: localSocketPath,
            remoteSocketPath: remoteSocketPath,
            stateFilePath: stateFilePath,
            session: session
        )
    }
}
