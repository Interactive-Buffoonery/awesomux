import Foundation

public struct GitWorktreeRecord: Equatable, Sendable {
    public var canonicalPath: URL
    public var headObjectID: String?
    public var branchRef: String?
    public var isDetached: Bool
    public var displayBranch: String
    public var isMainWorktree: Bool
    public var isBare: Bool
    public var lockReason: String?
    public var prunableReason: String?

    public init(
        canonicalPath: URL,
        headObjectID: String?,
        branchRef: String?,
        isDetached: Bool,
        displayBranch: String,
        isMainWorktree: Bool,
        isBare: Bool,
        lockReason: String?,
        prunableReason: String?
    ) {
        self.canonicalPath = canonicalPath
        self.headObjectID = headObjectID
        self.branchRef = branchRef
        self.isDetached = isDetached
        self.displayBranch = displayBranch
        self.isMainWorktree = isMainWorktree
        self.isBare = isBare
        self.lockReason = lockReason
        self.prunableReason = prunableReason
    }
}
