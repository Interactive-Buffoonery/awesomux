import Foundation

/// A fixed file-read destination, separate from terminal execution identity.
/// A fresh ID on every edit revokes previously captured read origins.
public struct RemoteFileContext: Equatable, Hashable, Sendable {
    public let id: UUID
    public let target: RemoteTarget
    public let baseDirectory: String

    public init(target: RemoteTarget, baseDirectory: String) {
        id = UUID()
        self.target = target
        self.baseDirectory = baseDirectory
    }
}
