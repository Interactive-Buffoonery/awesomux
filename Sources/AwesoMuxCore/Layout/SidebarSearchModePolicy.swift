public enum SidebarSearchModePolicy {
    public static func query(
        afterChangingTo displayMode: SidebarWidthMode,
        currentQuery: String
    ) -> String {
        displayMode == .collapsed ? "" : currentQuery
    }

    public static func showsNoMatches(
        isFiltering: Bool,
        hasVisibleResults: Bool,
        displayMode: SidebarWidthMode
    ) -> Bool {
        isFiltering && !hasVisibleResults && displayMode != .collapsed
    }
}
