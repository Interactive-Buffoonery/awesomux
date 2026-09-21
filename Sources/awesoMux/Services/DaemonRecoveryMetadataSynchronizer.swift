import AwesoMuxBridgeProtocol
import AwesoMuxCore

@MainActor
final class DaemonRecoveryMetadataSynchronizer {
    typealias Writer = @MainActor @Sendable (TerminalSessionID, DaemonRecoveryMetadata) async -> Bool

    private let writer: Writer
    private var written: [TerminalSessionID: DaemonRecoveryMetadata] = [:]
    private var pending: [SessionGroup]?
    private var isWriting = false

    init(writer: @escaping Writer = { await AmxBackend.setRecoveryMetadata($1, for: $0) }) {
        self.writer = writer
    }

    func synchronize(groups: [SessionGroup]) async {
        pending = groups
        guard !isWriting else { return }
        isWriting = true
        defer { isWriting = false }

        while let snapshot = pending {
            pending = nil
            for (id, metadata) in Self.localMetadata(in: snapshot) where written[id] != metadata {
                guard pending == nil else { break }
                if await writer(id, metadata) {
                    written[id] = metadata
                }
            }
        }
    }

    func invalidate() {
        written.removeAll()
    }

    private static func localMetadata(
        in groups: [SessionGroup]
    ) -> [(TerminalSessionID, DaemonRecoveryMetadata)] {
        groups.flatMap { group in
            group.sessions.flatMap { session in
                session.panes.compactMap { pane in
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
