import AwesoMuxBridgeProtocol
import AwesoMuxCore
import AwesoMuxLocalAPI
import AwesoMuxLocalAPIAccess
import Darwin
import Foundation
import os

enum LocalAPIProcessSource: Sendable, Equatable {
    case daemon(AmxDaemonIncarnation)
    case foreground(pid_t)

    nonisolated func agentIncarnation(provider: AgentKind) -> String? {
        var pid: pid_t
        switch self {
        case .daemon(let daemon):
            guard ProcessLivenessProbe.matchesDaemonIncarnation(daemon),
                let daemonPID = pid_t(exactly: daemon.pid),
                let foreground = ProcessLivenessProbe.terminalForegroundPID(daemonPID: daemonPID)
            else { return nil }
            pid = foreground
        case .foreground(let foreground):
            pid = foreground
        }
        var terminalDevice: UInt32?
        // A tool may own the foreground group; walk to the provider ancestor
        // on the same terminal, including provider-launched tool shells.
        for _ in 0..<16 {
            guard let comm = ProcessLivenessProbe.foregroundComm(pid: pid),
                let startedAt = ProcessLivenessProbe.processStartTime(pid: pid)
            else { return nil }
            var info = proc_bsdinfo()
            let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
            guard size == Int32(MemoryLayout<proc_bsdinfo>.size) else { return nil }
            if let terminalDevice, terminalDevice != info.e_tdev { return nil }
            terminalDevice = info.e_tdev
            if AgentPromptGate.foregroundCommandMatches(provider, observedCommand: comm) {
                guard ProcessLivenessProbe.processStartTime(pid: pid) == startedAt else { return nil }
                return "local:\(pid):\(startedAt)"
            }
            guard info.pbi_ppid > 1,
                let parent = pid_t(exactly: info.pbi_ppid), parent != pid
            else { return nil }
            pid = parent
        }
        return nil
    }
}

@MainActor
final class LocalAPIService {
    private let server: LocalAPIServer
    private static let logger = Logger(subsystem: "com.interactivebuffoonery.awesomux", category: "LocalAPI")

    init(
        store: SessionStore,
        runtime: GhosttyRuntime,
        accessStore: LocalAPIAccessStore,
        profile: AppRuntimeProfile = .current
    ) throws {
        let profileValue = profile.environmentValue
        guard accessStore.ownsAuthority, accessStore.loadFailure == nil else { throw LocalAPIError.accessDisabled }
        server = try LocalAPIServer(
            profile: profileValue,
            authorization: accessStore.runtimeAuthority.provider
        ) { [weak store, weak runtime] request, instance, lease in
            guard let store, let runtime else { return LocalAPIResponse(requestID: request.requestID, error: .appUnavailable) }
            store.bindLocalAPIInstance(instance)
            let operation = LocalAPIOperation(rawValue: request.operation)
            if operation == .agentContext {
                return await LocalAPIContextCapture.response(
                    request: request, instanceID: instance, lease: lease,
                    authorization: accessStore.runtimeAuthority.provider,
                    sample: {
                        guard let paneID = request.paneID else { throw LocalAPIError.invalidRequest }
                        return try await Self.sampleContextTarget(paneID: paneID, store: store, runtime: runtime)
                    },
                    read: { agent, source, limit in
                        guard let workspace = store.session(id: agent.workspaceID),
                            let pane = workspace.layout.pane(id: agent.paneID)
                        else { throw LocalAPIError.staleTarget }
                        guard case .local = pane.executionPlan else { throw LocalAPIError.remoteContext }
                        if source == .terminalHistory {
                            return (try await runtime.localAPIHistory(paneID: agent.paneID, limit: limit), false)
                        }
                        guard let kind = AgentKind(rawValue: agent.provider),
                            let home = AgentTranscriptPaneInputs.resolutionAttempts(
                                for: kind, integrations: runtime.agentIntegrations
                            ).first?.configHome
                        else { throw LocalAPIError.unsupportedProvider }
                        let plan = pane.executionPlan
                        let chrome = AgentTranscriptOpener.localizedChrome(agentKind: kind)
                        let worker = Task.detached(priority: .utility) {
                            try Task.checkCancellation()
                            return try LocalAPIContextReader.read(
                                agentKind: kind, executionPlan: plan, configHome: home,
                                sessionID: agent.providerSessionID, limit: limit, chrome: chrome
                            )
                        }
                        let rendered = try await withTaskCancellationHandler {
                            try await worker.value
                        } onCancel: {
                            worker.cancel()
                        }
                        return (rendered.text, rendered.isTruncated)
                    }
                )
            }
            var agents: [LocalAPIAgent]?
            var sampledIncarnations: [UUID: String] = [:]
            if operation == .listAgents || operation == .attentionEvents {
                let providers: [UUID: AgentKind]
                do {
                    providers = try store.localAPIProviders()
                } catch {
                    return LocalAPIResponse(requestID: request.requestID, error: .staleTarget)
                }
                let workspaceIDs = store.localAPIWorkspaceIDs()
                let candidatePaneIDs = Self.candidatePaneIDs(
                    for: lease.statusScope,
                    providers: providers,
                    workspaceIDs: workspaceIDs
                )
                let keys = store.localAPIRoutingKeys().filter { candidatePaneIDs.contains($0.key) }
                let sources = runtime.localAPIProcessSources().filter { candidatePaneIDs.contains($0.key) }
                let probeTask = Task.detached(priority: .utility) {
                    return sources.reduce(into: [UUID: String]()) { result, item in
                        guard !Task.isCancelled, let provider = providers[item.key], provider != .shell,
                            let incarnation = item.value.agentIncarnation(provider: provider)
                        else { return }
                        result[item.key] = incarnation
                    }
                }
                let incarnations = await withTaskCancellationHandler {
                    await probeTask.value
                } onCancel: {
                    probeTask.cancel()
                }
                guard !Task.isCancelled else { return LocalAPIResponse(requestID: request.requestID, error: .cancelled) }
                guard let currentProviders = try? store.localAPIProviders(), providers == currentProviders,
                    keys == store.localAPIRoutingKeys().filter({ candidatePaneIDs.contains($0.key) }),
                    sources == runtime.localAPIProcessSources().filter({ candidatePaneIDs.contains($0.key) })
                else { return LocalAPIResponse(requestID: request.requestID, error: .staleTarget) }
                sampledIncarnations = incarnations
                if operation == .listAgents {
                    agents = store.localAPIAgents(
                        processIncarnations: incarnations,
                        limitedTo: candidatePaneIDs
                    ).filter {
                        lease.statusScope.allows(
                            paneID: $0.paneID,
                            workspaceID: $0.workspaceID,
                            targetVersion: $0.targetVersion
                        )
                    }
                }
            }
            var attentionEvents: LocalAPIAttentionPage?
            if operation == .attentionEvents {
                do {
                    attentionEvents = try store.localAPIAttentionEvents(
                        cursor: request.cursor, limit: request.limit ?? 0, lease: lease,
                        processIncarnations: sampledIncarnations
                    )
                } catch {
                    return LocalAPIResponse(requestID: request.requestID, error: error as? LocalAPIError ?? .transportFailure)
                }
            }
            return LocalAPIResponse(
                requestID: request.requestID, profile: profileValue, appInstanceID: instance,
                capturedAt: Date(), connectionStatus: operation == .connectionStatus ? .connected : nil,
                capabilities: operation == .capabilities ? LocalAPICapabilities() : nil,
                agents: operation == .listAgents ? agents : nil,
                contextGrant: operation == .connectionStatus ? lease.contextGrant : nil,
                attentionEvents: attentionEvents
            )
        }
        accessStore.setInvalidationHandler { [weak server] connectionID in
            server?.invalidate(connectionID: connectionID)
        }
        store.bindLocalAPIInstance(server.instanceID)
        server.start()
    }

    func stop() { server.stop() }

    static func start(
        store: SessionStore,
        runtime: GhosttyRuntime,
        accessStore: LocalAPIAccessStore
    ) -> LocalAPIService? {
        // Bare SwiftPM test processes have no supported public runtime profile.
        guard case .test = AppRuntimeProfile.current else {
            do { return try LocalAPIService(store: store, runtime: runtime, accessStore: accessStore) } catch {
                accessStore.relinquishAuthority()
                logger.error("Local API unavailable: \(String(describing: error), privacy: .public)")
                return nil
            }
        }
        return nil
    }

    static func sampleContextTarget(
        paneID: UUID, store: SessionStore, runtime: GhosttyRuntime
    ) async throws -> LocalAPIAgent {
        let providers = try store.localAPIProviders()
        guard let provider = providers[paneID] else { throw LocalAPIError.staleTarget }
        let key = store.localAPIRoutingKeys()[paneID]
        let source = runtime.localAPIProcessSources()[paneID]
        let worker = Task.detached(priority: .utility) { source?.agentIncarnation(provider: provider) }
        let incarnation = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        try Task.checkCancellation()
        guard (try store.localAPIProviders())[paneID] == provider,
            store.localAPIRoutingKeys()[paneID] == key,
            runtime.localAPIProcessSources()[paneID] == source
        else { throw LocalAPIError.staleTarget }
        let incarnations = incarnation.map { [paneID: $0] } ?? [:]
        guard let agent = store.localAPIAgents(processIncarnations: incarnations, limitedTo: [paneID]).first else {
            throw LocalAPIError.staleTarget
        }
        return agent
    }

    private static func candidatePaneIDs(
        for scope: LocalAPITargetScope,
        providers: [UUID: AgentKind],
        workspaceIDs: [UUID: UUID]
    ) -> Set<UUID> {
        switch scope {
        case .exactTarget(let paneID, _):
            return providers[paneID] == nil ? [] : [paneID]
        case .persistentPanes(let paneIDs):
            return Set(paneIDs.filter { providers[$0] != nil })
        case .persistentWorkspaces(let allowedWorkspaceIDs):
            let allowed = Set(allowedWorkspaceIDs)
            return Set(workspaceIDs.compactMap { allowed.contains($0.value) ? $0.key : nil })
        }
    }
}
