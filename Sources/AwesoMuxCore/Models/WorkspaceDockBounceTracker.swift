import Foundation

public struct WorkspaceDockBounceTracker: Sendable {
    private var needsAttentionBySessionID: [TerminalSession.ID: Bool]

    public init(groups: [SessionGroup] = []) {
        needsAttentionBySessionID = Self.needsAttentionBySessionID(in: groups)
    }

    public mutating func reset(groups: [SessionGroup]) {
        needsAttentionBySessionID = Self.needsAttentionBySessionID(in: groups)
    }

    public mutating func shouldRequestDockBounce(
        afterUpdating groups: [SessionGroup],
        isAppActive: Bool = true,
        outputMarksNeedsAttention: Bool = true,
        allowsDockBounce: Bool = false
    ) -> Bool {
        var shouldBounce = false
        var seenSessionIDs = Set<TerminalSession.ID>()

        for group in groups {
            for session in group.sessions {
                seenSessionIDs.insert(session.id)

                let previousNeedsAttention = needsAttentionBySessionID[session.id] ?? false
                let currentNeedsAttention = Self.needsAttention(session)

                if currentNeedsAttention,
                   !previousNeedsAttention,
                   !isAppActive,
                   outputMarksNeedsAttention,
                   allowsDockBounce,
                   !session.notificationsMuted {
                    shouldBounce = true
                }

                needsAttentionBySessionID[session.id] = currentNeedsAttention
            }
        }

        for sessionID in Array(needsAttentionBySessionID.keys)
        where !seenSessionIDs.contains(sessionID) {
            needsAttentionBySessionID.removeValue(forKey: sessionID)
        }

        return shouldBounce
    }

    private static func needsAttentionBySessionID(
        in groups: [SessionGroup]
    ) -> [TerminalSession.ID: Bool] {
        var stateByID: [TerminalSession.ID: Bool] = [:]
        for group in groups {
            for session in group.sessions {
                stateByID[session.id] = needsAttention(session)
            }
        }
        return stateByID
    }

    private static func needsAttention(_ session: TerminalSession) -> Bool {
        session.agentRollup().state == .needsAttention
    }
}
