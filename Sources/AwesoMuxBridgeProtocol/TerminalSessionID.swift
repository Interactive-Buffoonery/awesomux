import Foundation

/// Durable awesoMux-owned terminal-session identity.
///
/// This is deliberately separate from `TerminalPane.ID`: pane UUIDs describe UI
/// identity, while this value names the durable backend session a pane reattaches
/// to across app launches. The current zmx-backed `amx` bridge uses the raw value
/// as the session name, so the byte ceiling is pinned here rather than leaking
/// through the UI model.
public struct TerminalSessionID: RawRepresentable, Codable, Hashable, Sendable {
    public static let maxAmxSessionNameUTF8Bytes = 46

    public let rawValue: String

    public init?(rawValue: String) {
        guard Self.isValid(rawValue) else {
            return nil
        }
        self.rawValue = rawValue
    }

    public static func generate() -> TerminalSessionID {
        // 36 ASCII bytes, safely below zmx's 46-byte session-name ceiling, while
        // staying opaque and independent from any pane UUID.
        TerminalSessionID(rawValue: UUID().uuidString.lowercased())!
    }

    public static func isValid(_ value: String) -> Bool {
        guard let first = value.unicodeScalars.first,
              value.utf8.count <= maxAmxSessionNameUTF8Bytes,
              value.range(of: "\0") == nil else {
            return false
        }
        guard (0x61...0x7a).contains(first.value)
              || (0x30...0x39).contains(first.value) else {
            return false
        }

        return value.unicodeScalars.allSatisfy { scalar in
            (0x61...0x7a).contains(scalar.value)
                || (0x30...0x39).contains(scalar.value)
                || scalar.value == 0x2d
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let id = TerminalSessionID(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid terminal session id."
            )
        }
        self = id
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

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
