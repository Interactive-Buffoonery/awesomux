import Foundation

public extension TerminalPaneLayout {
    var firstPane: TerminalPane? {
        switch self {
        case let .pane(pane):
            pane
        case let .split(split):
            split.first.firstPane ?? split.second.firstPane
        case .documentGroup:
            nil
        }
    }

    var firstPaneID: TerminalPane.ID {
        guard let id = firstPane?.id else {
            preconditionFailure("TerminalPaneLayout must contain at least one pane")
        }

        return id
    }

    var paneIDs: [TerminalPane.ID] {
        var ids: [TerminalPane.ID] = []
        appendPaneIDs(into: &ids)
        return ids
    }

    func appendPaneIDs(into ids: inout [TerminalPane.ID]) {
        switch self {
        case let .pane(pane):
            ids.append(pane.id)
        case let .split(split):
            split.first.appendPaneIDs(into: &ids)
            split.second.appendPaneIDs(into: &ids)
        case .documentGroup:
            break  // invisible to terminal enumeration
        }
    }

    /// Collects panes in one tree walk. `TerminalSession.panes` uses this so the
    /// rollup funnel is O(panes), not O(panes²) (collect-ids-then-re-find-each).
    func appendPanes(into panes: inout [TerminalPane]) {
        switch self {
        case let .pane(pane):
            panes.append(pane)
        case let .split(split):
            split.first.appendPanes(into: &panes)
            split.second.appendPanes(into: &panes)
        case .documentGroup:
            break  // invisible to terminal enumeration
        }
    }

    /// Visits each pane in tree order WITHOUT materializing an intermediate
    /// array — for hot loops that only read panes (no need for the `[TerminalPane]`
    /// allocation `panes`/`appendPanes(into:)` make per call).
    func forEachPane(_ body: (TerminalPane) -> Void) {
        switch self {
        case let .pane(pane):
            body(pane)
        case let .split(split):
            split.first.forEachPane(body)
            split.second.forEachPane(body)
        case .documentGroup:
            break  // invisible to terminal enumeration
        }
    }

    internal func appendRemotePaneIDs(into ids: inout Set<TerminalPane.ID>) {
        switch self {
        case let .pane(pane):
            if pane.remotePresentationHost != nil {
                ids.insert(pane.id)
            }
        case let .split(split):
            split.first.appendRemotePaneIDs(into: &ids)
            split.second.appendRemotePaneIDs(into: &ids)
        case .documentGroup:
            break  // no remote state on a document leaf
        }
    }

    func contains(paneID: TerminalPane.ID) -> Bool {
        switch self {
        case let .pane(pane):
            pane.id == paneID
        case let .split(split):
            split.first.contains(paneID: paneID)
                || split.second.contains(paneID: paneID)
        case .documentGroup:
            false  // document tab IDs are not terminal pane IDs
        }
    }

    /// Number of TERMINAL panes in this layout. `.documentGroup` leaves contribute 0.
    /// Use this to drive multi-pane UI chrome (pills, palette commands, a11y jump
    /// actions) — a terminal+doc session reads as 1 terminal, not 2.
    var paneCount: Int {
        switch self {
        case .pane:
            1
        case let .split(split):
            split.first.paneCount + split.second.paneCount
        case .documentGroup:
            0  // document leaves are invisible to terminal enumeration
        }
    }

    /// True when the layout contains exactly one terminal pane.
    /// A document-only layout (currently unreachable: `removingPane` enforces
    /// ≥1 terminal) returns false.
    var isSinglePane: Bool {
        paneCount == 1
    }

    var hasMultiplePanes: Bool {
        paneCount > 1
    }

    func split(id: TerminalSplit.ID) -> TerminalSplit? {
        switch self {
        case .pane:
            nil
        case let .split(split):
            if split.id == id {
                split
            } else {
                split.first.split(id: id) ?? split.second.split(id: id)
            }
        case .documentGroup:
            nil
        }
    }

    func pane(id: TerminalPane.ID) -> TerminalPane? {
        switch self {
        case let .pane(pane):
            pane.id == id ? pane : nil
        case let .split(split):
            split.first.pane(id: id) ?? split.second.pane(id: id)
        case .documentGroup:
            nil
        }
    }

    /// The first `.documentGroup` leaf in tree order. Reducers maintain an
    /// at-most-one-group invariant, so for well-formed layouts this IS the
    /// session's document viewer; for hand-edited multi-group layouts it is the
    /// deterministic pick (first in tree order).
    var firstDocumentGroup: DocumentGroup? {
        switch self {
        case .pane:
            nil
        case let .documentGroup(group):
            group
        case let .split(split):
            split.first.firstDocumentGroup ?? split.second.firstDocumentGroup
        }
    }

    /// Same tree shape, orientations, and pane membership as `other`, ignoring
    /// split UUIDs and `firstFraction`. Move operations mint fresh split IDs and
    /// reset fractions, so raw `==` would never recognize a rearrangement that
    /// reproduces the same visual layout. This is the no-op test that lets a
    /// pointless drag (e.g. the left pane back onto the left workspace edge) be
    /// rejected.
    func isStructurallyEquivalent(to other: TerminalPaneLayout) -> Bool {
        switch (self, other) {
        case let (.pane(lhs), .pane(rhs)):
            return lhs.id == rhs.id
        case let (.split(lhs), .split(rhs)):
            return lhs.orientation == rhs.orientation
                && lhs.first.isStructurallyEquivalent(to: rhs.first)
                && lhs.second.isStructurallyEquivalent(to: rhs.second)
        case let (.documentGroup(lhs), .documentGroup(rhs)):
            return lhs.id == rhs.id
        default:
            return false
        }
    }
}
