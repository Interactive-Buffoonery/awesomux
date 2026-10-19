import AwesoMuxBridgeProtocol
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

    /// Direct runtime sibling lookup with no migration fallback. Returns nil when the group
    /// is present but not directly split with exactly one terminal-bearing pane.
    func directTerminalSplitSibling(ofDocumentGroup id: DocumentGroup.ID) -> TerminalPane.ID? {
        findDirectTerminalSplitSibling(ofDocumentGroup: id)
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
