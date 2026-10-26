import AwesoMuxBridgeProtocol
import AwesoMuxCore
import AwesoMuxConfig
import AwesoMuxCompanionProtocol
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
struct CompanionDecisionResponse {
    let response: CompanionAPIResponse
    let validate: @MainActor () throws -> Void
}

@MainActor
final class LocalAPIService {
    private var awayMonitor: CompanionAwayMonitor?
    #if DEBUG
        private var decisionFixture: CompanionDecisionFixture?
        var hasDecisionFixture: Bool { decisionFixture != nil }
    #endif
    private let server: LocalAPIServer
    private let capture: LocalAPIServer.Capture
    private weak var renameStore: SessionStore?
    private let renameAuthority: LocalAPIRuntimeAuthority
    private let profileValue: String
    private weak var store: SessionStore?
    private weak var runtime: GhosttyRuntime?
    private weak var settings: AppSettingsStore?
    private static let logger = Logger(subsystem: "com.interactivebuffoonery.awesomux", category: "LocalAPI")

    init(
        store: SessionStore,
        runtime: GhosttyRuntime,
        accessStore: LocalAPIAccessStore,
        profile: AppRuntimeProfile = .current,
        settings: AppSettingsStore? = nil
    ) throws {
        let profileValue = profile.environmentValue
        guard accessStore.ownsAuthority, accessStore.loadFailure == nil else { throw LocalAPIError.accessDisabled }
        let capture: LocalAPIServer.Capture = { [weak store, weak runtime] request, instance, lease in
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
                        includeCommandEvents: request.includeCommandEvents ?? false, processIncarnations: sampledIncarnations
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
        self.profileValue = profileValue
        self.store = store
        self.runtime = runtime
        self.capture = capture
        self.settings = settings
        renameStore = store
        renameAuthority = accessStore.runtimeAuthority
        server = try LocalAPIServer(
            profile: profileValue,
            authorization: accessStore.runtimeAuthority.provider,
            capture: capture
        )
        accessStore.setInvalidationHandler { [weak server] connectionID in
            server?.invalidate(connectionID: connectionID)
        }
        store.companionAlertIsSuppressed = { [weak runtime] paneID in
            runtime?.companionAlertIsSuppressed(paneID: paneID) ?? false
        }
        store.bindLocalAPIInstance(server.instanceID)
        awayMonitor = CompanionAwayMonitor(store: store)
        #if DEBUG
            if case .development = profile,
                let path = ProcessInfo.processInfo.environment["AWESOMUX_COMPANION_DECISION_FIXTURE"],
                let session = store.groups.flatMap(\.sessions).first
            {
                decisionFixture = try CompanionDecisionFixture(directory: URL(fileURLWithPath: path), workspaceID: session.id)
            }
        #endif
        server.start()
    }

    func stop() {
        awayMonitor = nil
        server.stop()
    }

    func recordAuthenticatedCompanionActivity() {
        awayMonitor?.recordAuthenticatedActivity()
    }

    var instanceID: UUID { server.instanceID }

    func renameCompanionPane(
        request: CompanionPaneRenameRequest, lease: LocalAPIAuthorizationLease,
        certificateFingerprint: Data, deadline: ContinuousClock.Instant
    ) throws {
        guard let store = renameStore else { throw LocalAPIError.appUnavailable }
        try CompanionPaneRename.apply(
            request: request, store: store, authority: renameAuthority,
            certificateFingerprint: certificateFingerprint, lease: lease, deadline: deadline)
    }

    func createCompanionTerminal(
        request: CompanionTerminalCreateRequest, lease: LocalAPIAuthorizationLease,
        certificateFingerprint: Data, deadline: ContinuousClock.Instant
    ) throws -> CompanionTerminalCreated {
        guard let store else { throw LocalAPIError.appUnavailable }
        return try CompanionTerminalCreate.apply(
            request: request, store: store,
            defaultGroup: settings?.workspaces.value.defaultGroup ?? WorkspaceConfig.defaultValue.defaultGroup,
            authority: renameAuthority, certificateFingerprint: certificateFingerprint, lease: lease, deadline: deadline)
    }

    func prepareCompanionTerminal(
        paneID: UUID, targetVersion: UUID, lease: LocalAPIAuthorizationLease,
        certificateFingerprint: Data, deadline: ContinuousClock.Instant
    ) async throws -> LocalAPITerminalWatchTarget {
        guard let store, let runtime else { throw LocalAPIError.appUnavailable }
        let spawnAuthority = CompanionTerminalOpen.SpawnAuthority(
            paneID: paneID, targetVersion: targetVersion, store: store, authority: renameAuthority,
            certificateFingerprint: certificateFingerprint, lease: lease, deadline: deadline)
        return try await withTaskCancellationHandler {
            defer { spawnAuthority.cancel() }
            let target = try CompanionTerminalOpen.prepare(
                paneID: paneID, targetVersion: targetVersion, store: store, authority: renameAuthority,
                certificateFingerprint: certificateFingerprint, lease: lease, deadline: deadline
            ) { workspace, pane in
                guard runtime.isReady, runtime.isCommandBridgeEnabled else { throw LocalAPIError.terminalUnavailable }
                let integrations = settings?.agentIntegrations.value ?? .defaultValue
                let surface = runtime.surfaceView(
                    sessionStore: store, session: workspace, pane: pane,
                    enabledAgentRuntimeFileDropSources: AgentRuntimeConsent.enabledFileDropSources(from: integrations),
                    grokIconEnabled: integrations.grok.enabled)
                // Use the same launch/preflight path as a native mount without
                // selecting the workspace or moving the Mac's first responder.
                surface.createSurfaceIfNeeded(companionAuthority: spawnAuthority)
                guard !surface.commandBridgeEnactor.errorLatched else { throw LocalAPIError.paneDisconnected }
                guard surface.surface != nil || surface.commandBridgeEnactor.bridgePreflightInFlight else {
                    throw LocalAPIError.terminalUnavailable
                }
            }
            guard let sessionName = target.localSessionName else { throw LocalAPIError.terminalUnavailable }
            try await CompanionTerminalOpen.waitForSocket(
                at: AmxBackend.sessionSocketDirectory() + "/" + sessionName, deadline: deadline)
            return try CompanionTerminalOpen.prepare(
                paneID: paneID, targetVersion: targetVersion, store: store, authority: renameAuthority,
                certificateFingerprint: certificateFingerprint, lease: lease, deadline: deadline,
                hydrate: { _, _ in })
        } onCancel: {
            spawnAuthority.cancel()
        }
    }

    func companionDecisions(
        answer: CompanionDecisionAnswer?, lease: LocalAPIAuthorizationLease,
        fingerprint: Data, authority: LocalAPIRuntimeAuthority, deviceName: String,
        requestID: UUID
    ) throws -> CompanionDecisionResponse {
        guard let store, let runtime, lease.decisionsAllowed else {
            throw LocalAPIError.permissionDenied
        }
        #if DEBUG
            let coordinator = decisionFixture?.coordinator ?? runtime.localPermissionCoordinator
            let fixture = decisionFixture != nil
        #else
            let coordinator = runtime.localPermissionCoordinator
            let fixture = false
        #endif
        let eligible: (LocalPermissionTarget) -> Bool = { [weak self, weak store] target in
            #if DEBUG
                if self?.decisionFixture != nil { return true }
            #endif
            guard let store, let session = store.session(id: target.workspaceID),
                let pane = session.layout.pane(id: target.paneID)
            else { return false }
            return LocalPermissionPresentation.isEligible(
                executionPlan: pane.executionPlan, compactTerminalKind: store.compactTerminalKind)
        }
        let result = try coordinator.remoteResponse(
            answer: answer, deviceID: lease.connectionID, deviceName: deviceName,
            authorize: { body in
                try authority.performCompanionDecision(certificateFingerprint: fingerprint, lease: lease, body: body)
            },
            eligible: eligible, fixture: fixture)
        let response = CompanionAPIResponse(
            requestID: requestID, profile: profileValue,
            appInstanceID: server.instanceID, capturedAt: Date(), pendingDecisions: result.pending,
            decisionOutcomes: result.outcomes, decisionReceipt: result.receipt,
            remoteDecisionsEnabled: LocalPermissionCoordinator.remoteDecisionsEnabled(provider: "claudeCode", version: nil))
        let identities = result.pending.map(\.identity) + result.outcomes.map(\.identity) + (result.receipt.map { [$0.identity] } ?? [])
        return CompanionDecisionResponse(
            response: response,
            validate: {
                try coordinator.validateRemoteTargets(identities, eligible: eligible)
            })
    }

    func terminalWatchTarget(paneID: UUID) -> LocalAPITerminalWatchTarget? {
        guard let store, let target = store.localAPITerminalWatchTarget(paneID: paneID) else { return nil }
        return try? store.companionTerminalToOpen(paneID: paneID, targetVersion: target.targetVersion).2
    }

    func companionResponse(
        request: LocalAPIRequest,
        lease: LocalAPIAuthorizationLease,
        routes: CompanionRoutes? = nil
    ) async -> CompanionAPIResponse {
        if request.operation == CompanionOperation.connectionStatus.rawValue
            || request.operation == CompanionOperation.capabilities.rawValue
        {
            return CompanionAPIResponse(
                requestID: request.requestID, profile: profileValue,
                appInstanceID: server.instanceID, capturedAt: Date(),
                connectionStatus: request.operation == CompanionOperation.connectionStatus.rawValue ? "connected" : nil, routes: routes,
                terminalPreviewAllowed: lease.terminalPreviewAllowed,
                remoteDecisionsEnabled: LocalPermissionCoordinator.remoteDecisionsEnabled(provider: "claudeCode", version: nil),
                terminalStream: request.operation == CompanionOperation.capabilities.rawValue || lease.terminalWatchScope != nil
                    ? CompanionTerminalStream.Capabilities() : nil
            )
        }
        if request.operation == CompanionOperation.listPanes.rawValue {
            guard let store, let runtime else {
                return CompanionAPIResponse(requestID: request.requestID, error: LocalAPIError.appUnavailable.rawValue)
            }
            let workspaces = store.companionWorkspaces(terminalPreviewAllowed: lease.terminalPreviewAllowed) {
                paneID in
                runtime.companionLastOutputLine(paneID: paneID)
            }
            return CompanionAPIResponse(
                requestID: request.requestID, profile: profileValue,
                appInstanceID: server.instanceID, capturedAt: Date(), workspaces: workspaces
            )
        }
        return await capture(request, server.instanceID, lease).companionResponse
    }

    static func start(
        store: SessionStore,
        runtime: GhosttyRuntime,
        accessStore: LocalAPIAccessStore,
        settings: AppSettingsStore? = nil
    ) -> LocalAPIService? {
        // Bare SwiftPM test processes have no supported public runtime profile.
        guard case .test = AppRuntimeProfile.current else {
            do { return try LocalAPIService(store: store, runtime: runtime, accessStore: accessStore, settings: settings) } catch {
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
        case .allWorkspaces:
            return Set(providers.keys)
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

#if DEBUG
    /// Pairing transport proof only. This coordinator has no real hook or shell
    /// targets, and cannot enable the production provider/version release gate.
    @MainActor
    private final class CompanionDecisionFixture {
        let coordinator = LocalPermissionCoordinator(announcement: { _ in })
        init(directory: URL, workspaceID: UUID) throws {
            var identities: [String: CompanionDecisionIdentity] = [:]
            let paneID = UUID()
            for (name, workspace, expiry) in [
                ("live", workspaceID, 120.0), ("queued", workspaceID, 120.0), ("expired", workspaceID, 59.0), ("outside", UUID(), 120.0),
            ] {
                let event = directory.appendingPathComponent("decision-fixture-\(name).jsonl")
                identities[name] = try coordinator.seedRemoteFixture(
                    workspaceID: workspace, paneID: workspace == workspaceID ? paneID : UUID(), eventFile: event,
                    expiresIn: expiry
                ).companionIdentity
            }
            try CompanionProtocol.encoder().encode(identities).write(
                to: directory.appendingPathComponent("decision-identities.json"), options: .atomic)
        }
    }
#endif
