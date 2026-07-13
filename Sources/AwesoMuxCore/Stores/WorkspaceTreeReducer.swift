import Foundation
import UnicodeHygiene

struct WorkspaceTreeReducer: Sendable {
    @discardableResult
    static func addSession(
        to groups: inout [SessionGroup],
        selectedSession: TerminalSession?,
        title: String?,
        workingDirectory: String?,
        agentKind: AgentKind,
        groupName: String
    ) -> TerminalSession.ID {
        let syntheticTitle: SyntheticSessionTitle?
        let resolvedTitle: String
        if let title {
            syntheticTitle = nil
            resolvedTitle = title
        } else {
            let generated = nextSyntheticSessionTitle(in: groups, for: agentKind)
            syntheticTitle = generated
            resolvedTitle = generated.localizedTitle()
        }
        let lookupKey = SessionStoreText.groupLookupKey(groupName)
        let groupIndex = groups.firstIndex(where: {
            SessionStoreText.groupLookupKey($0.name)
                .caseInsensitiveCompare(lookupKey) == .orderedSame
        })
        let executionPlan =
            groupIndex.flatMap { groups[$0].remote }
            .map { PaneExecutionPlan.ssh(SSHExecution(target: $0)) }
            ?? .local
        let session = TerminalSession(
            title: resolvedTitle,
            workingDirectory: workingDirectory ?? selectedSession?.workingDirectory ?? "~",
            syntheticTitle: syntheticTitle,
            agentKind: agentKind,
            agentState: agentKind.initialSessionState,
            executionPlan: executionPlan
        )

        if let groupIndex {
            groups[groupIndex].sessions.append(session)
        } else {
            groups.append(SessionGroup(name: lookupKey, sessions: [session]))
        }

        return session.id
    }

    static func insertSession(
        _ session: TerminalSession,
        into groups: inout [SessionGroup],
        groupName: String
    ) {
        // Caller-supplied session carries its own ID (unlike `addSession`, which
        // mints a fresh one). Refuse a duplicate: two rows on one ID make
        // selection, close, and the promotion pulse resolve to the wrong tile.
        guard !groups.contains(where: { group in
            group.sessions.contains { $0.id == session.id }
        }) else {
            return
        }

        let lookupKey = SessionStoreText.groupLookupKey(groupName)
        if let groupIndex = groups.firstIndex(where: {
            SessionStoreText.groupLookupKey($0.name)
                .caseInsensitiveCompare(lookupKey) == .orderedSame
        }) {
            groups[groupIndex].sessions.append(session)
        } else {
            groups.append(SessionGroup(name: lookupKey, sessions: [session]))
        }
    }

    @discardableResult
    static func addWorkspaceGroup(
        to groups: inout [SessionGroup],
        selectedSession: TerminalSession?,
        named rawGroupName: String,
        workingDirectory: String?,
        agentKind: AgentKind,
        remote: RemoteTarget? = nil
    ) -> TerminalSession.ID? {
        let groupName = SessionStoreText.sanitizedGroupName(rawGroupName)
        guard !groupName.isEmpty,
              !UnicodeHygiene.hasSuspiciousScriptMixing(rawGroupName),
              !containsGroup(in: groups, named: groupName) else {
            return nil
        }

        let syntheticTitle = nextSyntheticSessionTitle(in: groups, for: agentKind)
        let session = TerminalSession(
            title: syntheticTitle.localizedTitle(),
            workingDirectory: workingDirectory ?? selectedSession?.workingDirectory ?? "~",
            syntheticTitle: syntheticTitle,
            agentKind: agentKind,
            agentState: agentKind.initialSessionState,
            executionPlan:
                remote
                .map { .ssh(SSHExecution(target: $0)) }
                ?? .local
        )

        groups.append(SessionGroup(name: groupName, remote: remote, sessions: [session]))
        return session.id
    }

    static func containsGroup(in groups: [SessionGroup], named rawGroupName: String) -> Bool {
        let groupName = SessionStoreText.sanitizedGroupName(rawGroupName)
        guard !groupName.isEmpty else {
            return false
        }

        return groups.contains { group in
            SessionStoreText.sanitizedGroupName(group.name)
                .caseInsensitiveCompare(groupName) == .orderedSame
        }
    }

    @discardableResult
    static func renameGroup(
        in groups: inout [SessionGroup],
        id groupID: SessionGroup.ID,
        to rawGroupName: String
    ) -> Bool {
        guard let groupIndex = groups.firstIndex(where: { $0.id == groupID }) else {
            return false
        }

        let groupName = SessionStoreText.sanitizedGroupName(rawGroupName)
        guard !groupName.isEmpty,
              !UnicodeHygiene.hasSuspiciousScriptMixing(rawGroupName) else {
            return false
        }

        let isDuplicate = groups.contains { group in
            group.id != groupID
                && SessionStoreText.sanitizedGroupName(group.name)
                    .caseInsensitiveCompare(groupName) == .orderedSame
        }
        guard !isDuplicate else {
            return false
        }

        guard groups[groupIndex].name != groupName else {
            return true
        }

        groups[groupIndex].name = groupName
        return true
    }

    @discardableResult
    static func setGroupColor(
        in groups: inout [SessionGroup],
        id groupID: SessionGroup.ID,
        color: WorkspaceGroupColor?
    ) -> Bool {
        guard let groupIndex = groups.firstIndex(where: { $0.id == groupID }) else {
            return false
        }

        guard groups[groupIndex].color != color else {
            return true
        }

        groups[groupIndex].color = color
        return true
    }

    static func removeGroup(in groups: inout [SessionGroup], id: SessionGroup.ID) -> Bool {
        guard let groupIndex = groups.firstIndex(where: { $0.id == id }),
              groups[groupIndex].sessions.isEmpty,
              groups.count > 1 else {
            return false
        }

        groups.remove(at: groupIndex)
        return true
    }

    static func moveSession(
        in groups: inout [SessionGroup],
        index: SessionStoreIndex,
        id sessionID: TerminalSession.ID,
        toGroupID destinationGroupID: SessionGroup.ID,
        atIndex targetIndex: Int
    ) -> Bool {
        guard let source = index.positionsBySessionID[sessionID],
              let destinationGroupIndex = groups.firstIndex(where: { $0.id == destinationGroupID }) else {
            return false
        }

        let destinationCount = source.groupIndex == destinationGroupIndex
            ? groups[destinationGroupIndex].sessions.count - 1
            : groups[destinationGroupIndex].sessions.count
        let clampedIndex = max(0, min(targetIndex, destinationCount))

        if source.groupIndex == destinationGroupIndex
            && clampedIndex == source.sessionIndex {
            return false
        }

        let session = groups[source.groupIndex].sessions.remove(at: source.sessionIndex)
        groups[destinationGroupIndex].sessions.insert(session, at: clampedIndex)
        return true
    }

    static func moveGroup(
        in groups: inout [SessionGroup],
        from sourceIndex: Int,
        to targetIndex: Int
    ) -> Bool {
        guard groups.indices.contains(sourceIndex) else {
            return false
        }
        let clampedTarget = max(0, min(targetIndex, groups.count - 1))
        guard clampedTarget != sourceIndex else {
            return false
        }

        let group = groups.remove(at: sourceIndex)
        let insertIndex = min(clampedTarget, groups.count)
        groups.insert(group, at: insertIndex)
        return true
    }

    static func replacementSelectionAfterClosingSession(
        in groups: [SessionGroup],
        at position: SessionStoreIndex.Position
    ) -> TerminalSession.ID? {
        let groupIndex = position.groupIndex
        let sessionIndex = position.sessionIndex

        if groups[groupIndex].sessions.indices.contains(sessionIndex + 1) {
            return groups[groupIndex].sessions[sessionIndex + 1].id
        }

        for nextGroupIndex in groups.indices.dropFirst(groupIndex + 1) {
            if let sessionID = groups[nextGroupIndex].sessions.first?.id {
                return sessionID
            }
        }

        if sessionIndex > 0 {
            return groups[groupIndex].sessions[sessionIndex - 1].id
        }

        guard groupIndex > 0 else {
            return nil
        }

        for previousGroupIndex in stride(from: groupIndex - 1, through: 0, by: -1) {
            if let sessionID = groups[previousGroupIndex].sessions.last?.id {
                return sessionID
            }
        }

        return nil
    }

    static func selectedSessionID(
        in groups: [SessionGroup],
        index: SessionStoreIndex,
        currentSelection: TerminalSession.ID?,
        offset: Int
    ) -> TerminalSession.ID? {
        let count = sessionCount(in: groups)
        guard count > 0 else {
            return nil
        }

        guard let currentSelection,
              let selectedPosition = index.positionsBySessionID[currentSelection] else {
            return firstSessionID(in: groups)
        }

        if offset == 1 {
            return sessionID(after: selectedPosition, in: groups)
        } else if offset == -1 {
            return sessionID(before: selectedPosition, in: groups)
        } else if offset != 0 {
            let currentIndex = flatSessionIndex(for: selectedPosition, in: groups)
            let nextIndex = wrappedIndex(currentIndex + offset, count: count)
            return sessionID(atFlatIndex: nextIndex, in: groups)
        } else {
            return currentSelection
        }
    }

    static func firstSessionID(in groups: [SessionGroup]) -> TerminalSession.ID? {
        groups.lazy.flatMap(\.sessions).first?.id
    }

    static func nextSessionTitle(in groups: [SessionGroup], for agentKind: AgentKind) -> String {
        nextSyntheticSessionTitle(in: groups, for: agentKind).localizedTitle()
    }

    static func nextSyntheticSessionTitle(
        in groups: [SessionGroup],
        for agentKind: AgentKind
    ) -> SyntheticSessionTitle {
        var existingTitles = Set<String>()
        var usedIndices = Set<Int>()
        var matchingAgentKindCount = 0

        for group in groups {
            for session in group.sessions {
                existingTitles.insert(session.title)
                if session.syntheticTitle?.agentKind == agentKind,
                   let index = session.syntheticTitle?.index {
                    usedIndices.insert(index)
                }
                if session.activeAgentKind == agentKind {
                    matchingAgentKindCount += 1
                }
            }
        }

        var index = matchingAgentKindCount + 1
        var candidate = SyntheticSessionTitle(agentKind: agentKind, index: index)
        while usedIndices.contains(index)
            || existingTitles.contains(candidate.localizedTitle())
            || existingTitles.contains(candidate.canonicalTitle) {
            index += 1
            candidate = SyntheticSessionTitle(agentKind: agentKind, index: index)
        }

        return candidate
    }

    private static func sessionID(
        after position: SessionStoreIndex.Position,
        in groups: [SessionGroup]
    ) -> TerminalSession.ID? {
        let groupIndex = position.groupIndex
        let sessionIndex = position.sessionIndex

        if groups[groupIndex].sessions.indices.contains(sessionIndex + 1) {
            return groups[groupIndex].sessions[sessionIndex + 1].id
        }

        for nextGroupIndex in groups.indices.dropFirst(groupIndex + 1) {
            if let sessionID = groups[nextGroupIndex].sessions.first?.id {
                return sessionID
            }
        }

        for wrappedGroupIndex in groups.indices.prefix(through: groupIndex) {
            let sessions = groups[wrappedGroupIndex].sessions
            guard !sessions.isEmpty else {
                continue
            }
            return sessions[0].id
        }

        return nil
    }

    private static func sessionID(
        before position: SessionStoreIndex.Position,
        in groups: [SessionGroup]
    ) -> TerminalSession.ID? {
        let groupIndex = position.groupIndex
        let sessionIndex = position.sessionIndex

        if sessionIndex > 0 {
            return groups[groupIndex].sessions[sessionIndex - 1].id
        }

        if groupIndex > 0 {
            for previousGroupIndex in stride(from: groupIndex - 1, through: 0, by: -1) {
                if let sessionID = groups[previousGroupIndex].sessions.last?.id {
                    return sessionID
                }
            }
        }

        for wrappedGroupIndex in stride(from: groups.count - 1, through: groupIndex, by: -1) {
            let sessions = groups[wrappedGroupIndex].sessions
            guard !sessions.isEmpty else {
                continue
            }
            return sessions[sessions.count - 1].id
        }

        return nil
    }

    private static func flatSessionIndex(
        for position: SessionStoreIndex.Position,
        in groups: [SessionGroup]
    ) -> Int {
        var flatIndex = position.sessionIndex

        for groupIndex in groups.indices.prefix(position.groupIndex) {
            flatIndex += groups[groupIndex].sessions.count
        }

        return flatIndex
    }

    private static func sessionID(
        atFlatIndex targetIndex: Int,
        in groups: [SessionGroup]
    ) -> TerminalSession.ID? {
        var remaining = targetIndex

        for group in groups {
            if remaining < group.sessions.count {
                return group.sessions[remaining].id
            }
            remaining -= group.sessions.count
        }

        return nil
    }

    private static func sessionCount(in groups: [SessionGroup]) -> Int {
        groups.reduce(0) { count, group in
            count + group.sessions.count
        }
    }

    private static func wrappedIndex(_ index: Int, count: Int) -> Int {
        let remainder = index % count
        return remainder >= 0 ? remainder : remainder + count
    }
}
