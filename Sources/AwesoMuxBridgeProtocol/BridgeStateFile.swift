import Foundation
import UnicodeHygiene

/// The `{proto, gen, socket, token}` bridge state file model:
///
/// ```json
/// {"proto":"awesomux-bridge-v1","gen":3,"socket":"/tmp/awesomux-bridge-9f3a1c…d2.sock","token":"4f3c…a19b"}
/// ```
///
/// The app atomically replaces this file (unique temp name + `rename(2)`) on
/// every attach; the remote helper reads it fresh at every invocation — per
/// the contributor ruling on INT-698, there is no durable helper-side epoch
/// cache, so this parse path (and `BridgeStateFileCustody`, which delivers
/// the bytes to it) runs on every read, not just the first.
public struct BridgeStateFile: Sendable, Equatable, Codable {
    /// Carried, not gated: `parse` deliberately does not reject an unknown
    /// `proto`. Version negotiation happens at the handshake (the spec's
    /// mandatory unknown-version reject lives there) — the state file only
    /// tells the helper which proto to *offer* in its `hello`, so a helper
    /// that supports a future v2 can keep using this same reader.
    public let proto: String
    public let gen: Int
    public let socket: String
    public let token: String

    public init(proto: String, gen: Int, socket: String, token: String) {
        self.proto = proto
        self.gen = gen
        self.socket = socket
        self.token = token
    }

    /// The spec's 4 KiB custody read cap. `BridgeStateFileCustody` already
    /// enforces this against the file's `st_size` before it ever reads a
    /// byte; this is a second, independent cap on the decode path itself, so
    /// a caller that obtains the bytes some other way (a test fixture, a
    /// future in-process transport) still can't hand this parser an
    /// unbounded buffer.
    public static let maximumByteCount = 4096

    private static let decoder = JSONDecoder()

    /// Decodes and validates a bridge state file's raw bytes. Returns `nil`
    /// — never a partially-trusted value — for an oversized buffer,
    /// malformed JSON, a missing required field, or a `socket` that is not
    /// an absolute path.
    ///
    /// The non-absolute-socket rejection matters because helpers never
    /// expand `~` (the same rule the spec states for `AWESOMUX_BRIDGE_STATE`
    /// itself): a relative or empty `socket` value is not a path this
    /// process could ever connect to, so treating the whole file as unusable
    /// is more honest than trying to interpret it relative to some assumed
    /// cwd.
    ///
    /// The scalar-safety fence on `socket` matters for a different reason
    /// than display spoofing: an embedded NUL means the NUL-terminated C
    /// string a later `connect(2)` actually receives is a *prefix* of the
    /// value this parser validated — "absolute path" would then describe a
    /// different path than the one used. Same fence
    /// (`containsUnsafePathScalars`) the spec mandates for every path field.
    public static func parse(data: Data) -> BridgeStateFile? {
        guard data.count <= maximumByteCount,
              let decoded = try? decoder.decode(BridgeStateFile.self, from: data),
              decoded.socket.hasPrefix("/"),
              !UnicodeHygiene.containsUnsafePathScalars(decoded.socket)
        else {
            return nil
        }
        return decoded
    }
}
