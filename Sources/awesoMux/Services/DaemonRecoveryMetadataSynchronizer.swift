import AwesoMuxBridgeProtocol
import AwesoMuxCore

@MainActor
final class DaemonRecoveryMetadataSynchronizer {
    typealias Writer = @MainActor @Sendable (TerminalSessionID, DaemonRecoveryMetadata) async -> Bool

    private let writer: Writer
    private let now: @MainActor () -> ContinuousClock.Instant
    private var written: [TerminalSessionID: DaemonRecoveryMetadata] = [:]
    private var retryAfter: [TerminalSessionID: ContinuousClock.Instant] = [:]
    private var pending: [SessionGroup]?
    private var isWriting = false

    init(
        now: @escaping @MainActor () -> ContinuousClock.Instant = { .now },
        writer: @escaping Writer = { await AmxBackend.setRecoveryMetadata($1, for: $0) }
    ) {
        self.now = now
        self.writer = writer
    }

    func synchronize(groups: [SessionGroup]) async {
        pending = groups
        guard !isWriting else { return }
        isWriting = true
        defer { isWriting = false }

        while let snapshot = pending {
            pending = nil
            let metadataByPane = Self.localMetadata(in: snapshot)
            let activeIDs = Set(snapshot.flatMap { $0.sessions }.flatMap { $0.panes }.map(\.terminalSessionID))
            retryAfter = retryAfter.filter { activeIDs.contains($0.key) }
            for (id, metadata) in metadataByPane where written[id] != metadata {
                guard pending == nil else { break }
                if let deadline = retryAfter[id], now() < deadline { continue }
                if await writer(id, metadata) {
                    written[id] = metadata
                    retryAfter[id] = nil
                } else {
                    // Retry the latest metadata on a later synchronization, not every tree mutation.
                    retryAfter[id] = now().advanced(by: .seconds(30))
                }
            }
        }
    }

    func invalidate() {
        written.removeAll()
        retryAfter.removeAll()
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
