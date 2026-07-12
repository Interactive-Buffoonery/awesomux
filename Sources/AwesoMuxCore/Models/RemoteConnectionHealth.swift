import Foundation

public enum RemoteConnectionHealth: String, Hashable, Sendable {
    case active
    case possiblyStale
}
