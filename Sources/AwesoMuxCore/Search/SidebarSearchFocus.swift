import Foundation

public enum SidebarSearchFocus {
    public static func target(
        after currentID: TerminalSession.ID?,
        in orderedIDs: [TerminalSession.ID],
        offset: Int
    ) -> TerminalSession.ID? {
        guard !orderedIDs.isEmpty else {
            return nil
        }

        guard let currentID,
            let currentIndex = orderedIDs.firstIndex(of: currentID)
        else {
            return offset < 0 ? orderedIDs.last : orderedIDs.first
        }

        let count = orderedIDs.count
        let wrappedIndex = (currentIndex + offset % count + count) % count
        return orderedIDs[wrappedIndex]
    }

    public static func reconcile(
        _ currentID: TerminalSession.ID?,
        from previousOrderedIDs: [TerminalSession.ID],
        to orderedIDs: [TerminalSession.ID]
    ) -> TerminalSession.ID? {
        guard let currentID else {
            return nil
        }
        guard !orderedIDs.isEmpty else {
            return nil
        }
        if orderedIDs.contains(currentID) {
            return currentID
        }

        guard let previousIndex = previousOrderedIDs.firstIndex(of: currentID) else {
            return orderedIDs.first
        }
        return orderedIDs[min(previousIndex, orderedIDs.count - 1)]
    }
}
