public struct SessionRestoreSanitizationSummary: Equatable, Sendable {
    public internal(set) var groupNameAdjustments: Int
    public internal(set) var droppedGroups: Int
    public internal(set) var mergedGroups: Int
    public internal(set) var sessionTitleAdjustments: Int
    public internal(set) var sessionWorkingDirectoryAdjustments: Int
    public internal(set) var paneTitleAdjustments: Int
    public internal(set) var paneWorkingDirectoryAdjustments: Int
    public internal(set) var collapsedLayouts: Int
    public internal(set) var activePaneFallbacks: Int
    public internal(set) var selectedSessionFallbacks: Int
    public internal(set) var droppedDocumentTabs: Int
    /// Duplicate group/session/split/pane IDs rewritten to fresh UUIDs during restore.
    /// These are structural-hygiene changes the user can't perceive, so they
    /// produce no `severitySummaryLines` — but they still alter the persisted
    /// graph, so they count toward `totalAdjustments` to trigger a recovery
    /// archive of the original snapshot before the cleaned state overwrites it.
    public internal(set) var idReassignments: Int

    public init(
        groupNameAdjustments: Int = 0,
        droppedGroups: Int = 0,
        mergedGroups: Int = 0,
        sessionTitleAdjustments: Int = 0,
        sessionWorkingDirectoryAdjustments: Int = 0,
        paneTitleAdjustments: Int = 0,
        paneWorkingDirectoryAdjustments: Int = 0,
        collapsedLayouts: Int = 0,
        activePaneFallbacks: Int = 0,
        selectedSessionFallbacks: Int = 0,
        droppedDocumentTabs: Int = 0,
        idReassignments: Int = 0
    ) {
        self.groupNameAdjustments = groupNameAdjustments
        self.droppedGroups = droppedGroups
        self.mergedGroups = mergedGroups
        self.sessionTitleAdjustments = sessionTitleAdjustments
        self.sessionWorkingDirectoryAdjustments = sessionWorkingDirectoryAdjustments
        self.paneTitleAdjustments = paneTitleAdjustments
        self.paneWorkingDirectoryAdjustments = paneWorkingDirectoryAdjustments
        self.collapsedLayouts = collapsedLayouts
        self.activePaneFallbacks = activePaneFallbacks
        self.selectedSessionFallbacks = selectedSessionFallbacks
        self.droppedDocumentTabs = droppedDocumentTabs
        self.idReassignments = idReassignments
    }

    public var totalAdjustments: Int {
        groupNameAdjustments
            + droppedGroups
            + mergedGroups
            + sessionTitleAdjustments
            + sessionWorkingDirectoryAdjustments
            + paneTitleAdjustments
            + paneWorkingDirectoryAdjustments
            + collapsedLayouts
            + activePaneFallbacks
            + selectedSessionFallbacks
            + droppedDocumentTabs
            + idReassignments
    }

    public var isEmpty: Bool {
        totalAdjustments == 0
    }

    /// True when there is at least one adjustment worth explaining to the user
    /// (a removed, changed, or fallback item). Structural `idReassignments`
    /// are deliberately excluded — they still need an archive, but there is
    /// nothing meaningful to say about them in the recovery alert.
    public var hasUserVisibleAdjustments: Bool {
        removedItemCount + changedItemCount + fallbackItemCount > 0
    }

    public var removedItemCount: Int {
        droppedGroups + collapsedLayouts + droppedDocumentTabs
    }

    public var changedItemCount: Int {
        groupNameAdjustments
            + mergedGroups
            + sessionTitleAdjustments
            + sessionWorkingDirectoryAdjustments
            + paneTitleAdjustments
            + paneWorkingDirectoryAdjustments
    }

    public var fallbackItemCount: Int {
        activePaneFallbacks
            + selectedSessionFallbacks
    }

    public var severitySummaryLines: [String] {
        [
            removedItemCount > 0
                ? "\(removedItemCount) \(Self.itemNoun(for: removedItemCount)) could not be restored and \(Self.wasWere(for: removedItemCount)) removed."
                : nil,
            changedItemCount > 0
                ? "\(changedItemCount) \(Self.itemNoun(for: changedItemCount)) \(Self.wasWere(for: changedItemCount)) cleaned up, such as invalid names or paths."
                : nil,
            fallbackItemCount > 0
                ? "\(fallbackItemCount) fallback \(Self.valueNoun(for: fallbackItemCount)) \(Self.wasWere(for: fallbackItemCount)) used."
                : nil,
        ].compactMap { $0 }
    }

    private static func itemNoun(for count: Int) -> String {
        count == 1 ? "item" : "items"
    }

    private static func valueNoun(for count: Int) -> String {
        count == 1 ? "value" : "values"
    }

    private static func wasWere(for count: Int) -> String {
        count == 1 ? "was" : "were"
    }
}
