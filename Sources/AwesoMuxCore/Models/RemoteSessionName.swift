import Foundation
import UnicodeHygiene

/// The name of a zmx session owned by the remote host. This reaches a remote
/// shell command line, so it is structured input rather than free text: the
/// accepted alphabet is `[A-Za-z0-9._-]`, which needs no quoting anywhere it is
/// interpolated.
public struct RemoteSessionName: Hashable, Sendable {
    public static let maxLength = 64

    public let rawValue: String

    /// Returns nil for anything that is not a safe socket-path component.
    /// `.` and `..` are rejected explicitly: zmx derives its socket path from
    /// the session name, so those would resolve to the socket directory or its
    /// parent. A leading `-` is rejected so the name can never be read as a
    /// flag by whatever runs it.
    public init?(rawValue: String) {
        guard !rawValue.isEmpty,
            rawValue.count <= Self.maxLength,
            !rawValue.hasPrefix("-"),
            rawValue != ".",
            rawValue != "..",
            rawValue.unicodeScalars.allSatisfy(Self.isAllowedScalar),
            !UnicodeHygiene.containsUnsafePathScalars(rawValue)
        else {
            return nil
        }
        self.rawValue = rawValue
    }

    private static func isAllowedScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "A"..."Z", "a"..."z", "0"..."9", ".", "_", "-":
            return true
        default:
            return false
        }
    }
}

extension RemoteSessionName: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let name = Self(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "\"\(rawValue)\" is not a valid remote session name."
            )
        }
        self = name
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
