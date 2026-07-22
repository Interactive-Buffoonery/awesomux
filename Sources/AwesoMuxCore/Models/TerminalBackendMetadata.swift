import Foundation

/// Opaque storage for backend-specific session state.
///
/// awesoMux code should treat this as a private payload owned by the current
/// persistent-terminal backend. Keeping it separate from `TerminalSessionID`
/// preserves the path from the zmx-backed `amx` bridge to a future native backend.
///
/// SECURITY: unlike `TerminalSessionID`, `rawValue` is NOT charset-validated and
/// its decoder is lenient (a malformed payload falls back to `.empty` rather than
/// throwing), so it can carry arbitrary attacker-controlled bytes from a crafted
/// snapshot — and it is now preserved across reopen (INT-578), so those bytes
/// outlive a single session. It is safe today ONLY because every consumer compares
/// it (`==`) and none interpolates it into a shell command, path, or URL. Do NOT
/// route `rawValue` into any exec/path/URL sink without validating it first.
public struct TerminalBackendMetadata: RawRepresentable, Codable, Hashable, Sendable {
    public static let empty = TerminalBackendMetadata(rawValue: "")

    public var rawValue: String

    public init(rawValue: String = "") {
        self.rawValue = rawValue
    }

    public var isEmpty: Bool {
        rawValue.isEmpty
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
