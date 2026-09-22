import AwesoMuxBridgeProtocol
import AwesoMuxCore

@MainActor
final class DaemonRecoveryMetadataSynchronizer {
    typealias Writer = @MainActor @Sendable (TerminalSessionID, DaemonRecoveryMetadata) async -> Bool

    private let writer: Writer
    private let now: @MainActor () -> ContinuousClock.Instant
    private let sleepUntil: @MainActor @Sendable (ContinuousClock.Instant) async throws -> Void
    private var written: [TerminalSessionID: DaemonRecoveryMetadata] = [:]
    private var retryAfter: [TerminalSessionID: ContinuousClock.Instant] = [:]
    private var pending: (groups: [SessionGroup], ids: Set<TerminalSessionID>?)?
    private var isWriting = false
    private var latestGroups: [SessionGroup] = []
    private var deferredWrite: Task<Void, Never>?
    private var deferredDeadline: ContinuousClock.Instant?
    private var deferredIDs: Set<TerminalSessionID> = []

    init(
        now: @escaping @MainActor () -> ContinuousClock.Instant = { .now },
        sleepUntil: @escaping @MainActor @Sendable (ContinuousClock.Instant) async throws -> Void = {
            try await ContinuousClock().sleep(until: $0)
        },
        writer: @escaping Writer = { await AmxBackend.setRecoveryMetadata($1, for: $0) }
    ) {
        self.now = now
        self.sleepUntil = sleepUntil
        self.writer = writer
    }

    deinit { deferredWrite?.cancel() }

    func synchronize(groups: [SessionGroup]) async {
        latestGroups = groups
        await synchronize(groups: groups, retrying: nil)
    }

    private func synchronize(groups: [SessionGroup], retrying ids: Set<TerminalSessionID>?) async {
        if let ids, let previous = pending {
            pending = (groups, previous.ids.map { $0.union(ids) })
        } else {
            pending = (groups, ids)
        }
        guard !isWriting else { return }
        isWriting = true
        defer { isWriting = false }

        while let snapshot = pending {
            pending = nil
            let metadataByPane = Self.localMetadata(in: snapshot.groups)
            let activeIDs = Set(snapshot.groups.flatMap { $0.sessions }.flatMap { $0.panes }.map(\.terminalSessionID))
            retryAfter = retryAfter.filter { activeIDs.contains($0.key) }
            var nextDeadline: ContinuousClock.Instant?
            var skippedIDs: Set<TerminalSessionID> = []
            for (id, metadata) in metadataByPane
            where written[id] != metadata && (snapshot.ids?.contains(id) ?? true) {
                guard pending == nil else { break }
                if let deadline = retryAfter[id], now() < deadline {
                    nextDeadline = min(nextDeadline ?? deadline, deadline)
                    skippedIDs.insert(id)
                    continue
                }
                if await writer(id, metadata) {
                    written[id] = metadata
                    retryAfter[id] = nil
                } else {
                    // Failure alone does not start an autonomous retry loop.
                    retryAfter[id] = now().advanced(by: .seconds(30))
                }
            }
            scheduleDeferredWrite(until: nextDeadline, ids: skippedIDs)
        }
    }

    func invalidate() {
        written.removeAll()
        retryAfter.removeAll()
        latestGroups = []
        scheduleDeferredWrite(until: nil, ids: [])
    }

    private func scheduleDeferredWrite(until deadline: ContinuousClock.Instant?, ids: Set<TerminalSessionID>) {
        deferredIDs = ids
        guard deferredDeadline != deadline else { return }
        deferredWrite?.cancel()
        deferredWrite = nil
        deferredDeadline = deadline
        guard let deadline else { return }
        let sleepUntil = sleepUntil
        // Keep the latest skipped update, without retaining this owner during the wait.
        deferredWrite = Task { [weak self] in
            do { try await sleepUntil(deadline) } catch { return }
            guard !Task.isCancelled, let self, self.deferredDeadline == deadline else { return }
            self.deferredWrite = nil
            self.deferredDeadline = nil
            let ids = self.deferredIDs
            self.deferredIDs = []
            // Consume only queued updates; failed flushes must not enqueue each other.
            await self.synchronize(groups: self.latestGroups, retrying: ids)
        }
    }

    private static func localMetadata(
        in groups: [SessionGroup]
    ) -> [(TerminalSessionID, DaemonRecoveryMetadata)] {
        groups.flatMap { group in
            group.sessions.flatMap { session in
                session.panes.compactMap { pane in
                    guard pane.terminalBackendMetadata == AmxBackend.establishedSessionMetadata else {
                        return nil
                    }
                    if case .ssh(let execution) = pane.executionPlan,
                        execution.persistenceOwner == .remoteZmx
                    {
                        return nil
                    }
                    return (
                        pane.terminalSessionID,
                        DaemonRecoveryMetadata(
                            workspaceTitle: session.title,
                            paneTitle: pane.title,
                            groupID: group.id,
                            groupName: group.name,
                            groupRemote: group.remote,
                            agentKind: pane.agentKind
                        )
                    )
                }
            }
        }
    }
}
