import AwesoMuxBridgeProtocol
import AwesoMuxLocalAPI
import Foundation

struct LocalAPITargetRecord {
    var workspaceID: UUID
    var terminalSessionID: String
    var executionPlan: PaneExecutionPlan
    var provider: AgentKind
    var runtimeEpoch: UUID?
    var providerSessionID: String?
    var processIncarnation: String?
    let assignmentVersion = UUID()
    var version = UUID()
}

public struct LocalAPIRoutingKey: Equatable, Sendable {
    let assignmentVersion: UUID
    let provider: AgentKind
    let runtimeEpoch: UUID?
    let providerSessionID: String?
}

public extension SessionStore {
    func bindLocalAPIInstance(_ instanceID: UUID) {
        guard localAPIInstanceID != instanceID else { return }
        localAPIInstanceID = instanceID
        localAPITargets.removeAll()
        reconcileLocalAPIAssignments()
    }

    func localAPIProviders() throws -> [UUID: AgentKind] {
        var providers: [UUID: AgentKind] = [:]
        for pane in groups.flatMap(\.sessions).flatMap(\.panes) {
            guard providers.updateValue(pane.agentKind, forKey: pane.id) == nil else {
                throw LocalAPIError.staleTarget
            }
        }
        return providers
    }

    func localAPIRoutingKeys() -> [UUID: LocalAPIRoutingKey] {
        localAPITracking = true
        reconcileLocalAPIAssignments()
        var keys: [UUID: LocalAPIRoutingKey] = [:]
        for session in groups.flatMap(\.sessions) {
            for pane in session.panes where pane.agentKind != .shell {
                guard let target = localAPITargets[pane.id] else { continue }
                let runtime = runtimeEventReducer.stateByPaneID[pane.id]
                keys[pane.id] = LocalAPIRoutingKey(
                    assignmentVersion: target.assignmentVersion, provider: pane.agentKind,
                    runtimeEpoch: runtime?.identityEpoch, providerSessionID: runtime?.providerSessionID
                )
            }
        }
        return keys
    }

    /// Snapshot capture shares native projection rules and has no selection or
    /// acknowledgment effects. Process observations are supplied by the app.
    func localAPIAgents(processIncarnations: [UUID: String] = [:], at now: Date = Date()) -> [LocalAPIAgent] {
        localAPITracking = true
        reconcileLocalAPIAssignments()
        let titles = sidebarResolvedTitles()
        return groups.flatMap { group in
            group.sessions.flatMap { session in
                session.panes.compactMap { pane -> LocalAPIAgent? in
                    let snapshot = pane.agentSnapshot(at: now)
                    guard snapshot.agentKind != .shell else { return nil }
                    let runtime = runtimeEventReducer.stateByPaneID[pane.id]
                    let sessionID = runtime?.providerSessionID
                    let incarnation = processIncarnations[pane.id]
                    guard var target = localAPITargets[pane.id] else { return nil }
                    if target.provider != pane.agentKind || target.runtimeEpoch != runtime?.identityEpoch
                        || target.providerSessionID != sessionID || target.processIncarnation != incarnation
                    {
                        target.version = UUID()
                        target.provider = pane.agentKind
                        target.runtimeEpoch = runtime?.identityEpoch
                        target.providerSessionID = sessionID
                        target.processIncarnation = incarnation
                        localAPITargets[pane.id] = target
                    }
                    let provenance =
                        pane.agentKindIsRuntimeEstablished ? "native_projection_with_provider_hooks" : "native_inference_or_restore"
                    return LocalAPIAgent(
                        paneID: pane.id, workspaceID: session.id,
                        workspaceName: titles[session.id] ?? session.title,
                        provider: pane.agentKind.rawValue,
                        executionLocation: pane.executionPlan.remoteTarget?.sshDestination ?? "local",
                        availability: PaneAvailability.of(.terminal(pane)).rawValue,
                        state: snapshot.state.rawValue, attentionReason: snapshot.attentionReason?.rawValue,
                        unreadCount: snapshot.unread, stateProvenance: provenance,
                        observedAt: pane.agentKindIsRuntimeEstablished ? runtime?.statusObservedAt : nil,
                        capturedAt: now, targetVersion: target.version,
                        identityEvidence: incarnation == nil ? "process_identity_unknown" : "local_process_incarnation",
                        providerSessionID: sessionID, capabilities: ["status"]
                    )
                }
            }
        }
    }

    func validateLocalAPITarget(paneID: UUID, targetVersion: UUID, processIncarnations: [UUID: String]) -> Bool {
        localAPIAgents(processIncarnations: processIncarnations).contains {
            $0.paneID == paneID && $0.targetVersion == targetVersion
        }
    }
}

extension SessionStore {
    func reconcileLocalAPIAssignments() {
        guard localAPITracking else { return }
        var live = Set<UUID>()
        for group in groups {
            for session in group.sessions {
                for pane in session.panes {
                    live.insert(pane.id)
                    reconcileLocalAPIAssignment(pane, workspaceID: session.id)
                }
            }
        }
        localAPITargets = localAPITargets.filter { live.contains($0.key) }
    }

    func reconcileLocalAPIAssignment(_ pane: TerminalPane, workspaceID: UUID) {
        guard localAPITracking else { return }
        let terminalID = pane.terminalSessionID.rawValue
        if let existing = localAPITargets[pane.id], existing.workspaceID == workspaceID,
            existing.terminalSessionID == terminalID, existing.executionPlan == pane.executionPlan,
            existing.provider == pane.agentKind
        {
            return
        }
        localAPITargets[pane.id] = LocalAPITargetRecord(
            workspaceID: workspaceID, terminalSessionID: terminalID,
            executionPlan: pane.executionPlan, provider: pane.agentKind
        )
    }

}
