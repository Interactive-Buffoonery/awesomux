public enum CompactTerminalKind: Equatable, Sendable {
    case floatingPanel
    case popUpTerminal

    public static let spawnEnvironmentKey = "AWESOMUX_COMPACT_TERMINAL"

    public static func applyingSpawnMarkers(
        to environment: [String: String],
        kind: CompactTerminalKind?
    ) -> [String: String] {
        guard let kind else { return environment }
        var marked = environment
        marked[spawnEnvironmentKey] = "1"
        if kind == .floatingPanel {
            marked[FloatingPanelStoreFactory.spawnEnvironmentKey] = "1"
        }
        return marked
    }
}
