public struct SessionManagerChange: Equatable, Sendable {
    public enum Kind: Sendable { case activityChanged, lifecycleChanged, appeared, disappeared }
    public let id: TerminalSessionID
    public let kind: Kind
    public let spoken: String
}

/// Pure diff of two resolved row snapshots into spoken-announcement deltas. The
/// app layer debounces + posts these via NSAccessibility (mirrors
/// `WorkspaceAttentionAnnouncementTracker`). Lifecycle changes take precedence
/// over activity changes in the same tick — a daemon going owned→abandoned is
/// the more important thing to hear than any concurrent idle↔busy flip.
public enum SessionManagerSnapshotDiffer {
    public static func changes(from old: [DaemonRow], to new: [DaemonRow]) -> [SessionManagerChange] {
        let oldByID = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let newByID = Dictionary(new.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [SessionManagerChange] = []

        for row in new {
            guard let prior = oldByID[row.id] else {
                result.append(.init(id: row.id, kind: .appeared, spoken: appeared(row)))
                continue
            }
            if prior.lifecycle != row.lifecycle {
                result.append(.init(id: row.id, kind: .lifecycleChanged, spoken: lifecycle(row)))
            } else if prior.activity != row.activity {
                result.append(.init(id: row.id, kind: .activityChanged, spoken: activity(row)))
            }
        }
        for row in old where newByID[row.id] == nil {
            result.append(.init(id: row.id, kind: .disappeared, spoken: disappeared(row)))
        }
        return result
    }

    private static func name(_ row: DaemonRow) -> String { row.owner ?? "an unowned session" }
    private static func activity(_ row: DaemonRow) -> String { "\(name(row)) is now \(row.activity.rawValue)." }
    private static func lifecycle(_ row: DaemonRow) -> String { "\(name(row)) is now \(row.lifecycle.rawValue)." }
    private static func appeared(_ row: DaemonRow) -> String { "New session \(name(row))." }
    private static func disappeared(_ row: DaemonRow) -> String { "Session \(name(row)) ended." }
}
