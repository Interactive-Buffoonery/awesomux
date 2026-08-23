import Foundation

public struct PaneMoveOrigin: Codable, Hashable, Sendable {
    /// References are best-effort: restore may re-mint IDs, in which case
    /// Return uses its documented active-pane fallback.
    public enum Sibling: Codable, Hashable, Sendable {
        case pane(TerminalPane.ID)
        case split(TerminalSplit.ID)
        case documentGroup(DocumentGroup.ID)
    }

    public var sourceSessionID: TerminalSession.ID
    public var paneID: TerminalPane.ID
    public var parentSplitID: TerminalSplit.ID
    public var sibling: Sibling
    public var edge: PaneMoveEdge
    public var fraction: Double

    public init(
        sourceSessionID: TerminalSession.ID,
        paneID: TerminalPane.ID,
        parentSplitID: TerminalSplit.ID,
        sibling: Sibling,
        edge: PaneMoveEdge,
        fraction: Double
    ) {
        self.sourceSessionID = sourceSessionID
        self.paneID = paneID
        self.parentSplitID = parentSplitID
        self.sibling = sibling
        self.edge = edge
        self.fraction = fraction
    }
}
