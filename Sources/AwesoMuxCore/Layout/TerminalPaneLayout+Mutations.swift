import Foundation

public extension TerminalPaneLayout {
    func replacingPane(
        id: TerminalPane.ID,
        with replacement: TerminalPaneLayout
    ) -> TerminalPaneLayout? {
        switch self {
        case let .pane(pane):
            return pane.id == id ? replacement : nil

        case let .split(split):
            if let first = split.first.replacingPane(id: id, with: replacement) {
                return .split(split.rebuilding(first: first))
            }

            if let second = split.second.replacingPane(id: id, with: replacement) {
                return .split(split.rebuilding(second: second))
            }

            return nil

        case .documentGroup:
            return nil  // a document leaf never matches a terminal pane ID
        }
    }

    internal func markingRemotePanesPossiblyStale() -> (layout: TerminalPaneLayout, didChange: Bool) {
        switch self {
        case var .pane(pane):
            guard pane.remotePresentationHost != nil,
                pane.remoteConnectionHealth != .possiblyStale
            else {
                return (self, false)
            }
            pane.remoteConnectionHealth = .possiblyStale
            return (.pane(pane), true)

        case let .split(split):
            let first = split.first.markingRemotePanesPossiblyStale()
            let second = split.second.markingRemotePanesPossiblyStale()
            guard first.didChange || second.didChange else {
                return (self, false)
            }
            return (
                .split(split.rebuilding(first: first.layout, second: second.layout)),
                true
            )

        case .documentGroup:
            return (self, false)  // no remote connection state on a document leaf
        }
    }

    /// Replaces the `.documentGroup` leaf with the given `id` without changing
    /// the surrounding split structure. Returns `nil` when the id is not present.
    func replacingDocumentGroup(
        id: DocumentGroup.ID,
        with replacement: DocumentGroup
    ) -> TerminalPaneLayout? {
        switch self {
        case .pane:
            return nil

        case let .documentGroup(group):
            return group.id == id ? .documentGroup(replacement) : nil

        case let .split(split):
            if let first = split.first.replacingDocumentGroup(id: id, with: replacement) {
                return .split(split.rebuilding(first: first))
            }

            if let second = split.second.replacingDocumentGroup(id: id, with: replacement) {
                return .split(split.rebuilding(second: second))
            }

            return nil
        }
    }

    /// Removes the `.documentGroup` leaf with the given `id` from the tree.
    /// If the group is one side of a split, the split collapses to its
    /// surviving sibling (mirroring `removingPane`). Returns `nil` when the
    /// id is not found so callers can treat a missing id as a no-op.
    func removingDocumentGroup(id: DocumentGroup.ID) -> TerminalPaneLayout? {
        switch self {
        case .pane:
            return nil  // terminal leaves never match a group id

        case let .split(split):
            // Direct match on first child
            if case let .documentGroup(group) = split.first, group.id == id {
                return split.second
            }
            // Recurse into first subtree
            if let first = split.first.removingDocumentGroup(id: id) {
                return .split(split.rebuilding(first: first))
            }

            // Direct match on second child
            if case let .documentGroup(group) = split.second, group.id == id {
                return split.first
            }
            // Recurse into second subtree
            if let second = split.second.removingDocumentGroup(id: id) {
                return .split(split.rebuilding(second: second))
            }

            return nil  // id not found anywhere in this split

        case .documentGroup:
            // A group at the layout root: direct matches are handled by the
            // parent split's explicit check before recursion, so reaching here
            // means this leaf didn't match — return nil (not found).
            return nil
        }
    }

    func removingPane(id: TerminalPane.ID) -> TerminalPaneLayout? {
        // Invariant: a session must always contain ≥1 terminal pane — but that
        // is a property of the ROOT, enforced here, not of every subtree. The
        // recursion below deliberately lets a document-only survivor bubble up
        // so an ancestor split can keep it seated beside the remaining
        // terminals: the document group's tabs each carry their own terminal
        // association (INT-748), so removing the terminal that happens to be
        // the group's structural split sibling must not silently destroy every
        // open document. Only when the WHOLE layout would end up terminal-free
        // (the last terminal closed) does this return nil so the caller closes
        // the session.
        guard let result = removingPanePreservingDocuments(id: id),
            result.firstPane != nil
        else {
            return nil
        }
        return result
    }

    private func removingPanePreservingDocuments(id: TerminalPane.ID) -> TerminalPaneLayout? {
        switch self {
        case let .pane(pane):
            return pane.id == id ? nil : self

        case let .split(split):
            if split.first.contains(paneID: id) {
                if let first = split.first.removingPanePreservingDocuments(id: id) {
                    return .split(split.rebuilding(first: first))
                }

                // The first side vanished with the removed pane; the survivor
                // may be document-only — keep it and let the root guard decide.
                return split.second
            }

            if split.second.contains(paneID: id) {
                if let second = split.second.removingPanePreservingDocuments(id: id) {
                    return .split(split.rebuilding(second: second))
                }

                return split.first
            }

            return self

        case .documentGroup:
            return self  // a terminal ID never matches a document leaf
        }
    }

    /// Wraps the whole layout in a fresh root split, placing `pane` on the given
    /// edge of it (first slot for `up`/`left`, second for `down`/`right`) at a
    /// 0.5 fraction. The existing tree is reparented untouched — no pane is
    /// recreated. Used to drop a detached pane against a workspace edge.
    func wrappedInRootSplit(
        adding pane: TerminalPane,
        on edge: PaneMoveEdge
    ) -> TerminalPaneLayout {
        let moved = TerminalPaneLayout.pane(pane)
        let split =
            edge.placesMovedPaneFirst
            ? TerminalSplit(orientation: edge.orientation, first: moved, second: self)
            : TerminalSplit(orientation: edge.orientation, first: self, second: moved)
        return .split(split)
    }

    /// Replaces the pane `targetID` with a fresh split that puts `pane` on the
    /// given edge of the target. Returns nil if `targetID` is absent. The target
    /// and moved panes are reparented untouched — neither is recreated.
    func splittingPane(
        id targetID: TerminalPane.ID,
        adding pane: TerminalPane,
        on edge: PaneMoveEdge
    ) -> TerminalPaneLayout? {
        guard let target = self.pane(id: targetID) else {
            return nil
        }
        let moved = TerminalPaneLayout.pane(pane)
        let targetLayout = TerminalPaneLayout.pane(target)
        let split =
            edge.placesMovedPaneFirst
            ? TerminalSplit(orientation: edge.orientation, first: moved, second: targetLayout)
            : TerminalSplit(orientation: edge.orientation, first: targetLayout, second: moved)
        return replacingPane(id: targetID, with: .split(split))
    }

    /// Exchanges the positions of two distinct panes in place. Tree shape,
    /// orientations, and fractions are untouched; only the two `TerminalPane`
    /// values swap slots. Returns nil if either id is absent or they are equal.
    func swappingPanes(
        _ firstID: TerminalPane.ID,
        _ secondID: TerminalPane.ID
    ) -> TerminalPaneLayout? {
        guard firstID != secondID,
            let firstPane = self.pane(id: firstID),
            let secondPane = self.pane(id: secondID)
        else {
            return nil
        }

        return mappingPanes { pane in
            if pane.id == firstID {
                secondPane
            } else if pane.id == secondID {
                firstPane
            } else {
                pane
            }
        }
    }

    func resizingSplit(id: TerminalSplit.ID, firstFraction: Double) -> TerminalPaneLayout {
        switch self {
        case .pane:
            return self

        case let .split(split):
            if split.id == id {
                return .split(split.rebuilding(firstFraction: firstFraction))
            }

            let first = split.first.resizingSplit(id: id, firstFraction: firstFraction)
            if first != split.first {
                return .split(split.rebuilding(first: first))
            }

            let second = split.second.resizingSplit(id: id, firstFraction: firstFraction)
            if second != split.second {
                return .split(split.rebuilding(second: second))
            }

            return self

        case .documentGroup:
            return self
        }
    }

    func resizingSplit(containing paneID: TerminalPane.ID, by delta: Double) -> TerminalPaneLayout? {
        switch self {
        case .pane:
            return nil

        case let .split(split):
            if let first = split.first.resizingSplit(containing: paneID, by: delta) {
                return .split(split.rebuilding(first: first))
            }

            if let second = split.second.resizingSplit(containing: paneID, by: delta) {
                return .split(split.rebuilding(second: second))
            }

            if split.first.contains(paneID: paneID) {
                return .split(split.rebuilding(firstFraction: split.firstFraction + delta))
            }

            if split.second.contains(paneID: paneID) {
                return .split(split.rebuilding(firstFraction: split.firstFraction - delta))
            }

            return nil

        case .documentGroup:
            return nil  // document leaves have no terminal pane ID to resize by
        }
    }

    func mappingPanes(_ transform: (TerminalPane) -> TerminalPane) -> TerminalPaneLayout {
        switch self {
        case let .pane(pane):
            return .pane(transform(pane))

        case let .split(split):
            return .split(
                split.rebuilding(
                    first: split.first.mappingPanes(transform),
                    second: split.second.mappingPanes(transform)
                )
            )

        case .documentGroup:
            return self  // transform applies to terminal panes only
        }
    }
}
