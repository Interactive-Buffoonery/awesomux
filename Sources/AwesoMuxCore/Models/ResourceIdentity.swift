import Foundation
import UnicodeHygiene

public struct ResourcePath: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct ResourceIdentity: Codable, Hashable, Sendable {
    public let location: ExecutionLocation
    public let path: ResourcePath

    public init(location: ExecutionLocation, path: ResourcePath) {
        self.location = location
        self.path = path
    }
}

public extension ResourceIdentity {
    var remoteTarget: RemoteTarget? {
        guard case .remote(let target) = location else { return nil }
        return target
    }

    var remoteDisplayOrigin: String? {
        remoteTarget.map { "\($0.sshDestination):\(path.rawValue)" }
    }

    var isSupportedRemoteMarkdownSnapshot: Bool {
        guard remoteTarget?.isSafeSSHDestination == true else { return false }
        return Self.isSupportedRemoteMarkdownPath(path.rawValue)
    }

    static func isSupportedRemoteMarkdownPath(_ path: String) -> Bool {
        guard !path.isEmpty,
            !path.contains("\0"),
            !path.hasPrefix("~") || path.hasPrefix("~/"),
            !UnicodeHygiene.containsUnsafePathScalars(path),
            DocumentURLValidator.allowedExtensions.contains(
                (path as NSString).pathExtension.lowercased()
            )
        else {
            return false
        }
        return path.hasPrefix("/") || path.hasPrefix("~/")
    }
}
