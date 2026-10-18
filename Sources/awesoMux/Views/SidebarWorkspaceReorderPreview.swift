import CoreGraphics

struct SidebarWorkspaceReorderPreview<ID: Hashable> {
    let offsets: [ID: CGFloat]
    let gapFrame: CGRect

    static func insertionIndex(
        forDropY y: CGFloat,
        sourceID: ID,
        currentInsertionIndex: Int?,
        orderedIDs: [ID],
        frames: [ID: CGRect]
    ) -> Int? {
        guard let sourceIndex = orderedIDs.firstIndex(of: sourceID),
            let sourceFrame = frames[sourceID],
            orderedIDs.allSatisfy({ (frames[$0]?.height ?? 0) > 0 })
        else { return nil }
        let insertion = max(0, min(currentInsertionIndex ?? sourceIndex, orderedIDs.count))
        let gapY =
            insertion < sourceIndex
            ? frames[orderedIDs[insertion]]!.minY
            : insertion > sourceIndex + 1 ? frames[orderedIDs[insertion - 1]]!.maxY - sourceFrame.height : sourceFrame.minY
        // A tall source can overlap several original hit targets. Keep its
        // visible gap stable until the pointer actually leaves that gap.
        if y >= gapY && y <= gapY + sourceFrame.height {
            return insertion
        }
        var nearest = sourceIndex
        var distance = CGFloat.infinity
        for target in orderedIDs.indices {
            let frame = frames[orderedIDs[target]]!
            let gapY =
                target < sourceIndex
                ? frame.minY
                : target == sourceIndex ? sourceFrame.minY : frame.maxY - sourceFrame.height
            let candidateDistance = abs(y - (gapY + sourceFrame.height / 2))
            if candidateDistance < distance {
                nearest = target
                distance = candidateDistance
            }
        }
        return nearest <= sourceIndex ? nearest : nearest + 1
    }

    init?(
        sourceID: ID,
        insertionIndex: Int?,
        orderedIDs: [ID],
        frames: [ID: CGRect],
        spacing: CGFloat
    ) {
        guard let sourceIndex = orderedIDs.firstIndex(of: sourceID),
            let sourceFrame = frames[sourceID],
            orderedIDs.allSatisfy({ (frames[$0]?.height ?? 0) > 0 })
        else { return nil }

        let insertion = max(0, min(insertionIndex ?? sourceIndex, orderedIDs.count))
        var offsets: [ID: CGFloat] = [:]
        var gapFrame = sourceFrame
        let displacement = sourceFrame.height + spacing
        if insertion < sourceIndex {
            for index in insertion..<sourceIndex {
                offsets[orderedIDs[index]] = displacement
            }
            gapFrame.origin.y = frames[orderedIDs[insertion]]!.minY
        } else if insertion > sourceIndex + 1 {
            for index in (sourceIndex + 1)..<insertion {
                offsets[orderedIDs[index]] = -displacement
            }
            gapFrame.origin.y = frames[orderedIDs[insertion - 1]]!.maxY - sourceFrame.height
        }
        self.offsets = offsets
        self.gapFrame = gapFrame
    }
}
