import Foundation

public enum ExecutionLocation: Hashable, Sendable {
    case local
    case remote(RemoteTarget)
}

extension ExecutionLocation: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case target
    }

    private enum Kind: String, Codable {
        case local
        case remote
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .local:
            guard !container.contains(.target) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .target,
                    in: container,
                    debugDescription: "A local execution location cannot contain a remote target."
                )
            }
            self = .local
        case .remote:
            self = .remote(try container.decode(RemoteTarget.self, forKey: .target))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .local:
            try container.encode(Kind.local, forKey: .kind)
        case .remote(let target):
            try container.encode(Kind.remote, forKey: .kind)
            try container.encode(target, forKey: .target)
        }
    }
}
