import Foundation

public enum DocumentNudgeUnavailableReason: Hashable, Sendable {
    case readOnlyRemoteSnapshot
    case foregroundSSH
    case localTerminalUnverified
    case terminalUnavailable
    case requiresLocalTerminal
    /// The target terminal is not a verified live supported-agent surface — a
    /// plain shell, an unknown TUI, an out-of-scope provider, or an agent pane
    /// whose foreground process could not be positively confirmed
    /// (`AgentPromptGate`, INT-569).
    case noVerifiedAgent
    case agentIntegrationDisabled(AgentKind)
    /// The verified agent is not waiting at its prompt (running, thinking,
    /// needing attention, done, or errored).
    case agentNotReceptive(AgentKind)
}

public enum DocumentNudgeTargetResolution: Hashable, Sendable {
    case available(TerminalPane)
    case unavailable(DocumentNudgeUnavailableReason)
}

public extension TerminalPaneLayout {
    /// Resolves the exact terminal eligible to receive a document nudge.
    /// Availability and execution both consume this result so a declared SSH
    /// plan cannot receive a path from the Mac filesystem.
    func documentNudgeTarget(for documentID: DocumentPane.ID) -> DocumentNudgeTargetResolution {
        guard let document = firstDocumentGroup?.tab(id: documentID) else {
            return .unavailable(.terminalUnavailable)
        }
        guard !document.isReadOnlySnapshot else {
            return .unavailable(.readOnlyRemoteSnapshot)
        }
        guard let target = documentSendTarget(for: documentID) else {
            return .unavailable(.terminalUnavailable)
        }
        guard
            ExecutionContext(plan: target.executionPlan)
                .capability(.stageLocalDocumentPath).isAllowed
        else {
            return .unavailable(.requiresLocalTerminal)
        }
        return .available(target)
    }

    /// Returns the terminal pane that should receive the selected document tab's
    /// Send to Agent nudge.
    ///
    /// A live stored association wins. A stale stored association fails closed:
    /// in the tabbed document model, the group's structural sibling can belong to
    /// a different tab. Only nil associations may recover to the direct split
    /// sibling.
    func documentSendTarget(for documentID: DocumentPane.ID) -> TerminalPane? {
        guard let group = firstDocumentGroup,
            let tab = group.tab(id: documentID)
        else {
            return nil
        }
        if let associatedID = tab.associatedTerminalPaneID {
            return pane(id: associatedID)
        }
        guard let siblingID = directTerminalSplitSibling(ofDocumentGroup: group.id) else {
            return nil
        }
        return pane(id: siblingID)
    }

    /// Direct runtime sibling lookup with no migration fallback. Unlike
    /// `nearestTerminalSibling(ofDocumentGroup:)`, this returns nil when the group
    /// is present but not directly split with exactly one terminal-bearing pane.
    func directTerminalSplitSibling(ofDocumentGroup id: DocumentGroup.ID) -> TerminalPane.ID? {
        findDirectTerminalSplitSibling(ofDocumentGroup: id)
    }

    /// Returns the ID of the terminal pane that shares a split with the given
    /// document group — its direct "split sibling". Returns `nil` when the group
    /// id is not present in this layout at all.
    ///
    /// MIGRATION-ONLY since INT-748: live routing (send/stage, file-browser root)
    /// reads each tab's stored `associatedTerminalPaneID` instead of inferring
    /// from split adjacency. This helper survives solely to backfill nil
    /// associations when a pre-v5 snapshot (one single-tab group per legacy
    /// `.document` leaf, each still at its original split position) migrates —
    /// adjacency is exactly what the old behavior targeted, so it is the correct
    /// backfill source there and nowhere else.
    ///
    /// The defensive fallback for a group that IS in the layout but not in a
    /// split is to return the first terminal pane in the tree. This differs from
    /// the unknown-ID case, which returns nil.
    func nearestTerminalSibling(ofDocumentGroup id: DocumentGroup.ID) -> TerminalPane.ID? {
        switch findTerminalSibling(ofDocumentGroup: id) {
        case .found(let terminalID):
            return terminalID
        case .presentButNotInSplit:
            // Group is in the layout but the tree traversal found no split
            // wrapping it directly. Return the first terminal as a last resort.
            return firstPane?.id
        case .notFound:
            return nil
        }
    }

    // MARK: - Private traversal

    private enum SiblingSearchResult {
        case found(TerminalPane.ID)  // the direct split-sibling terminal
        case presentButNotInSplit  // group exists but has no split parent here
        case notFound  // group id absent from this subtree
    }

    /// Recursive helper. Searches for the group's direct split sibling.
    private func findTerminalSibling(ofDocumentGroup id: DocumentGroup.ID) -> SiblingSearchResult {
        switch self {
        case .pane:
            return .notFound

        case let .documentGroup(group):
            // A bare group leaf with no split parent above it (in the recursion
            // context that reached here) — indicates the group exists but
            // was never a direct child of any split we visited.
            return group.id == id ? .presentButNotInSplit : .notFound

        case let .split(split):
            // Direct child check first — if the group is IMMEDIATELY inside
            // this split, return the first terminal reachable from the other branch.
            if case let .documentGroup(group) = split.first, group.id == id {
                if let siblingID = split.second.firstPane?.id {
                    return .found(siblingID)
                }
                return .presentButNotInSplit
            }
            if case let .documentGroup(group) = split.second, group.id == id {
                if let siblingID = split.first.firstPane?.id {
                    return .found(siblingID)
                }
                return .presentButNotInSplit
            }

            // Not a direct child — recurse into both branches.
            let firstResult = split.first.findTerminalSibling(ofDocumentGroup: id)
            if case .notFound = firstResult {
                return split.second.findTerminalSibling(ofDocumentGroup: id)
            }
            return firstResult
        }
    }

    private func findDirectTerminalSplitSibling(ofDocumentGroup id: DocumentGroup.ID) -> TerminalPane.ID? {
        switch self {
        case .pane, .documentGroup:
            return nil

        case let .split(split):
            if case let .documentGroup(group) = split.first, group.id == id {
                return split.second.onlyTerminalPaneID
            }
            if case let .documentGroup(group) = split.second, group.id == id {
                return split.first.onlyTerminalPaneID
            }
            return split.first.findDirectTerminalSplitSibling(ofDocumentGroup: id)
                ?? split.second.findDirectTerminalSplitSibling(ofDocumentGroup: id)
        }
    }

    private var onlyTerminalPaneID: TerminalPane.ID? {
        let ids = paneIDs
        return ids.count == 1 ? ids[0] : nil
    }
}
