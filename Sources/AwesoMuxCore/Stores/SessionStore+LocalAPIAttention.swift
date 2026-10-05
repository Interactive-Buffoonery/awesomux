import AwesoMuxLocalAPI
import Foundation

struct LocalAPIActiveAttention {
    let assignmentVersion: UUID
    let runtimeEpoch: UUID?
    let event: LocalAPIAttentionEvent

    func matches(assignmentVersion: UUID, runtimeEpoch: UUID?, providerSessionID: String?, reason: String) -> Bool {
        self.assignmentVersion == assignmentVersion && self.runtimeEpoch == runtimeEpoch
            && event.providerSessionID == providerSessionID && event.reason == reason
    }
}

public extension SessionStore {
    func localAPIAttentionEvents(
        cursor: String?, limit: Int, lease: LocalAPIAuthorizationLease,
        processIncarnations: [UUID: String] = [:]
    ) throws -> LocalAPIAttentionPage {
        _ = try localAPIProviders()
        guard let journal = localAPIAttentionJournal else { throw LocalAPIError.appUnavailable }
        var liveVersions: [UUID: UUID] = [:]
        if case .exactTarget(let paneID, let grantedVersion) = lease.statusScope {
            for agent in localAPIAgents(processIncarnations: processIncarnations, limitedTo: [paneID]) {
                liveVersions[agent.paneID] = agent.targetVersion
            }
            guard liveVersions[paneID] == grantedVersion else { throw LocalAPIError.staleTarget }
        }
        return try journal.page(cursor: cursor, limit: limit, lease: lease, liveTargetVersions: liveVersions)
    }
}

extension SessionStore {
    func recordLocalAPIAttentionChanges(at now: Date = Date()) {
        guard localAPIAttentionJournal != nil, (try? localAPIProviders()) != nil else { return }
        reconcileLocalAPIAssignments()
        var activePaneIDs = Set<UUID>()
        for session in groups.flatMap(\.sessions) {
            for pane in session.panes where pane.agentKind != .shell {
                let snapshot = pane.agentSnapshot()
                let reason: String
                if let attention = snapshot.attentionReason {
                    reason = attention.rawValue
                } else if snapshot.state == .waiting {
                    reason = "waitingForInput"
                } else if snapshot.state == .error {
                    reason = "agentError"
                } else {
                    continue
                }
                guard let target = localAPITargets[pane.id] else { continue }
                activePaneIDs.insert(pane.id)
                if let previous = localAPIActiveAttention[pane.id] {
                    if previous.matches(
                        assignmentVersion: target.assignmentVersion, runtimeEpoch: target.runtimeEpoch,
                        providerSessionID: target.providerSessionID, reason: reason
                    ) {
                        continue
                    }
                    resolveLocalAPIAttention(paneID: pane.id, at: now)
                }
                let event = LocalAPIAttentionEvent(
                    attentionID: UUID(), change: .raised, paneID: pane.id,
                    workspaceID: session.id, provider: pane.agentKind.rawValue,
                    providerSessionID: target.providerSessionID, targetVersion: target.version,
                    occurredAt: now, reason: reason
                )
                localAPIAttentionJournal?.append(event)
                localAPIActiveAttention[pane.id] = LocalAPIActiveAttention(
                    assignmentVersion: target.assignmentVersion, runtimeEpoch: target.runtimeEpoch, event: event
                )
            }
        }
        for paneID in localAPIActiveAttention.keys.sorted(by: { $0.uuidString < $1.uuidString }) where !activePaneIDs.contains(paneID) {
            resolveLocalAPIAttention(paneID: paneID, at: now)
        }
    }

    private func resolveLocalAPIAttention(paneID: UUID, at now: Date) {
        guard let prior = localAPIActiveAttention.removeValue(forKey: paneID)?.event else { return }
        localAPIAttentionJournal?.append(
            LocalAPIAttentionEvent(
                attentionID: prior.attentionID, change: .resolved,
                paneID: prior.paneID, workspaceID: prior.workspaceID, provider: prior.provider,
                providerSessionID: prior.providerSessionID, targetVersion: prior.targetVersion,
                occurredAt: now, reason: prior.reason, resolvedAt: now
            ))
    }
}
