import AwesoMuxBridgeProtocol
import Foundation
import UnicodeHygiene

/// userInfo key `WorkspaceNotificationBridge` stamps at post time so a
/// notification click can be routed back to its source workspace.
public enum WorkspaceNotificationUserInfoKey {
    public static let sessionID = "workspaceSessionID"
    /// Stamped so the foreground-presentation handler can tell a turn-done ping
    /// (sound-only when focused) from a needs-attention banner (list-only when
    /// focused). Value is `"turnDone"` for turn-done, absent/other otherwise.
    public static let kind = "workspaceNotificationKind"
    public static let turnDoneKindValue = "turnDone"
}

/// Decodes the routing decision for a clicked workspace notification. Kept
/// separate from `UNUserNotificationCenterDelegate` glue so the userInfo →
/// session-ID mapping is testable without `UserNotifications`.
public enum WorkspaceNotificationRouting {
    public static func sessionID(fromUserInfo userInfo: [AnyHashable: Any]) -> TerminalSession.ID? {
        guard let raw = userInfo[WorkspaceNotificationUserInfoKey.sessionID] as? String else {
            return nil
        }
        return UUID(uuidString: raw)
    }
}

public struct WorkspaceNotificationEvent: Equatable, Sendable {
    /// What kind of transition produced this banner, so the bridge can pick copy
    /// and presentation. `.needsAttention` is the louder permission/attention
    /// path; `.turnDone` is the quieter "agent finished its turn, waiting for
    /// you" ping (INT-650 turn-end `.waiting`).
    public enum Kind: Equatable, Sendable {
        case needsAttention
        case turnDone
    }

    private static let maxNotificationTitleLength = 200
    private static let maxNotificationContextLength = 120
    private static let maxNotificationContextComponentLength = 80

    /// Resolved once per process — the home directory is constant for a process
    /// lifetime, so re-reading `FileManager` per event/path is pure waste.
    /// Internal (not private) because it's the default argument for
    /// `displayContextsBySessionID`, which is called from another file.
    /// Canonical (not raw `FileManager` home) so the prefix strip below matches
    /// the canonicalized-at-ingest `session.workingDirectory` under a symlinked
    /// home (INT-498).
    static let processHomeDirectory = WorkingDirectoryValidator.canonicalHomeDirectory

    public let sessionID: TerminalSession.ID
    public let title: String
    public let groupName: String?
    public let workingDirectory: String?
    public let displayContext: String?
    public let agentKind: AgentKind
    public let unreadNotificationCount: Int
    public let kind: Kind

    public init(
        sessionID: TerminalSession.ID,
        title: String,
        groupName: String? = nil,
        workingDirectory: String? = nil,
        displayContext: String? = nil,
        agentKind: AgentKind,
        unreadNotificationCount: Int,
        kind: Kind = .needsAttention
    ) {
        self.sessionID = sessionID
        self.title = Self.sanitizedTitle(title) ?? ""
        self.groupName = Self.sanitizedGroupName(groupName)
        self.workingDirectory = workingDirectory
        self.displayContext = Self.sanitizedContext(displayContext)
            ?? Self.defaultDisplayContext(
                groupName: groupName,
                workingDirectory: workingDirectory
            )
        self.agentKind = agentKind
        self.unreadNotificationCount = unreadNotificationCount
        self.kind = kind
    }

    public func notificationSubtitle(showWorkspaceDetails: Bool) -> String {
        // The workspace title is baseline identity and always shows (matching
        // pre-INT-24 behavior) so multi-agent users can tell banners apart. The
        // opt-in only gates the extra group/path *context*, which is where a
        // username or project path could leak.
        guard showWorkspaceDetails, let displayContext, !displayContext.isEmpty else {
            return title
        }

        guard !title.isEmpty else {
            return displayContext
        }

        return "\(title) · \(displayContext)"
    }

    static func displayContextsBySessionID(
        in groups: [SessionGroup],
        homeDirectory: String = WorkspaceNotificationEvent.processHomeDirectory
    ) -> [TerminalSession.ID: String] {
        let sources = groups.flatMap { group in
            group.sessions.map { session in
                ContextSource(
                    sessionID: session.id,
                    titleKey: sanitizedTitle(session.title) ?? "",
                    groupContext: sanitizedGroupName(group.name),
                    directoryComponents: directoryComponents(
                        from: session.workingDirectory,
                        homeDirectory: homeDirectory
                    )
                )
            }
        }

        var result: [TerminalSession.ID: String] = [:]
        for titleGroup in Dictionary(grouping: sources, by: \.titleKey).values {
            var resolved: [TerminalSession.ID: String] = [:]
            let maximumDepth = titleGroup.map(\.directoryComponents.count).max() ?? 0
            if maximumDepth > 0 {
                for depth in 1...maximumDepth {
                    var sourcesByContext: [String: [ContextSource]] = [:]
                    for source in titleGroup where resolved[source.sessionID] == nil {
                        guard let context = source.directoryContext(depth: depth) else {
                            continue
                        }

                        sourcesByContext[context, default: []].append(source)
                    }

                    for (context, matchingSources) in sourcesByContext where matchingSources.count == 1 {
                        resolved[matchingSources[0].sessionID] = context
                    }
                }
            }

            for source in titleGroup where resolved[source.sessionID] == nil {
                guard let fallback = source.fallbackContext else {
                    continue
                }

                resolved[source.sessionID] = fallback
            }

            // Exact-duplicate tiebreaker: sessions sharing an identical resolved
            // context (same title + group + cwd) can't be split by path. Append
            // a stable ordinal, in source order, so notifications stay
            // distinguishable — mirroring the sidebar's duplicate ordinals.
            var idsByContext: [String: [TerminalSession.ID]] = [:]
            for source in titleGroup {
                guard let context = resolved[source.sessionID] else { continue }
                idsByContext[context, default: []].append(source.sessionID)
            }

            for source in titleGroup {
                guard let context = resolved[source.sessionID] else { continue }
                let collidingIDs = idsByContext[context] ?? []
                guard collidingIDs.count > 1,
                      let ordinal = collidingIDs.firstIndex(of: source.sessionID) else {
                    result[source.sessionID] = context
                    continue
                }

                result[source.sessionID] = "\(context) (\(ordinal + 1) of \(collidingIDs.count))"
            }
        }

        return result
    }

    private static func defaultDisplayContext(
        groupName: String?,
        workingDirectory: String?
    ) -> String? {
        workingDirectoryContext(workingDirectory)
            ?? sanitizedGroupName(groupName)
    }

    private static func workingDirectoryContext(_ workingDirectory: String?) -> String? {
        let components = directoryComponents(
            from: workingDirectory,
            homeDirectory: processHomeDirectory
        )
        guard let leaf = components.last else {
            return nil
        }

        return sanitizedContext(leaf)
    }

    private static func directoryComponents(
        from workingDirectory: String?,
        homeDirectory: String
    ) -> [String] {
        guard let path = normalizedDirectoryPath(workingDirectory), path != "~" else {
            return []
        }

        let normalizedHome = normalizedDirectoryPath(homeDirectory)
        if let normalizedHome, path == normalizedHome {
            return []
        }

        let relativePath: String
        if path.hasPrefix("~/") {
            relativePath = String(path.dropFirst(2))
        } else if let normalizedHome, path.hasPrefix(normalizedHome + "/") {
            relativePath = String(path.dropFirst(normalizedHome.count + 1))
        } else {
            relativePath = path
        }

        return relativePath
            .split(separator: "/", omittingEmptySubsequences: true)
            .compactMap { sanitizedContextComponent(String($0)) }
    }

    private static func normalizedDirectoryPath(_ rawValue: String?) -> String? {
        guard var path = nonEmpty(rawValue) else {
            return nil
        }

        while path.hasSuffix("/"), path.count > 1 {
            path.removeLast()
        }

        return path
    }

    private static func sanitizedTitle(_ rawValue: String?) -> String? {
        sanitized(rawValue, maxLength: maxNotificationTitleLength)
    }

    private static func sanitizedGroupName(_ rawValue: String?) -> String? {
        guard let rawValue else {
            return nil
        }

        // Group names are banner grouping keys, so they share the routing-key
        // stripping SessionStoreText applies — joiner-differing names must not
        // produce distinct banner contexts.
        let value = UnicodeHygiene.sanitize(
            rawValue,
            maxLength: maxNotificationContextComponentLength,
            stripInvisibleRoutingScalars: true
        )
        return value.isEmpty ? nil : value
    }

    private static func sanitizedContext(_ rawValue: String?) -> String? {
        sanitized(rawValue, maxLength: maxNotificationContextLength)
    }

    private static func sanitizedContextComponent(_ rawValue: String?) -> String? {
        sanitized(rawValue, maxLength: maxNotificationContextComponentLength)
    }

    private static func sanitized(_ rawValue: String?, maxLength: Int) -> String? {
        guard let rawValue else {
            return nil
        }

        let value = UnicodeHygiene.sanitize(rawValue, maxLength: maxLength)
        return value.isEmpty ? nil : value
    }

    private static func nonEmpty(_ rawValue: String?) -> String? {
        guard let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }

        return value
    }

    private struct ContextSource {
        var sessionID: TerminalSession.ID
        var titleKey: String
        var groupContext: String?
        var directoryComponents: [String]

        var fallbackContext: String? {
            if let groupContext, let fullDirectoryContext {
                return sanitizedContext("\(groupContext) · \(fullDirectoryContext)")
            }

            return groupContext ?? fullDirectoryContext
        }

        var fullDirectoryContext: String? {
            directoryContext(depth: directoryComponents.count)
        }

        func directoryContext(depth: Int) -> String? {
            guard depth > 0, !directoryComponents.isEmpty else {
                return nil
            }

            let suffix = directoryComponents.suffix(min(depth, directoryComponents.count))
            return sanitizedContext(suffix.joined(separator: "/"))
        }
    }
}
