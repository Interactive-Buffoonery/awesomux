import Foundation

public struct RemoteForegroundLivenessReport: Codable, Hashable, Sendable {
    public static let currentVersion = 1
    public static let maximumEncodedByteCount = 512

    public enum State: String, Codable, Hashable, Sendable {
        case idleShell = "idle-shell"
        case busyShell = "busy-shell"
        case liveCommand = "live-command"
        case indeterminate
        case gone
    }

    public let v: Int
    public let state: State
    public let comm: String?
    public let hasChildren: Bool?

    public init(
        v: Int = Self.currentVersion,
        state: State,
        comm: String? = nil,
        hasChildren: Bool? = nil
    ) {
        self.v = v
        self.state = state
        self.comm = comm
        self.hasChildren = hasChildren
    }

    enum CodingKeys: String, CodingKey {
        case v, state, comm, hasChildren
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumEncodedByteCount else {
            throw EncodingError.invalidValue(
                self,
                .init(
                    codingPath: [],
                    debugDescription: "Remote liveness report exceeds the protocol bound."
                )
            )
        }
        return data
    }
}
