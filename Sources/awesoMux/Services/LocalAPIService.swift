#if AWESOMUX_LOCAL_API_E2E && !DEBUG
    #error("The local API E2E host must never be built in release configuration")
#endif

import AwesoMuxBridgeProtocol
import AwesoMuxCore
import AwesoMuxLocalAPI
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

    init(store: SessionStore, runtime: GhosttyRuntime, profile: AppRuntimeProfile = .current) throws {
        let profileValue = profile.environmentValue
        // No production toggle or environment variable enables access. This
        // compile-only host is built by the E2E driver, never release staging.
        #if AWESOMUX_LOCAL_API_E2E && DEBUG
            guard case .development = profile else { throw LocalAPIError.accessDisabled }
            let authorization: LocalAPIServer.Authorization = { _ in nil }
        #else
            let authorization: LocalAPIServer.Authorization = { _ in .accessDisabled }
        #endif
        server = try LocalAPIServer(profile: profileValue, authorization: authorization) { [weak store, weak runtime] request, instance in
            guard let store, let runtime else { return LocalAPIResponse(requestID: request.requestID, error: .appUnavailable) }
            store.bindLocalAPIInstance(instance)
            let operation = LocalAPIOperation(rawValue: request.operation)
            var agents: [LocalAPIAgent]?
            if operation == .listAgents {
                let keys = store.localAPIRoutingKeys()
                let sources = runtime.localAPIProcessSources()
                let providers = Dictionary(
                    uniqueKeysWithValues: store.groups.flatMap(\.sessions).flatMap(\.panes).map { ($0.id, $0.agentKind) })
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
                guard keys == store.localAPIRoutingKeys(), sources == runtime.localAPIProcessSources()
                else { return LocalAPIResponse(requestID: request.requestID, error: .staleTarget) }
                agents = store.localAPIAgents(processIncarnations: incarnations)
            }
            return LocalAPIResponse(
                requestID: request.requestID, profile: profileValue, appInstanceID: instance,
                capturedAt: Date(), connectionStatus: operation == .connectionStatus ? .connected : nil,
                capabilities: operation == .capabilities ? LocalAPICapabilities() : nil,
                agents: agents
            )
        }
        server.start()
    }

    func stop() { server.stop() }

    static func start(store: SessionStore, runtime: GhosttyRuntime) -> LocalAPIService? {
        // Bare SwiftPM test processes have no supported public runtime profile.
        guard case .test = AppRuntimeProfile.current else {
            do { return try LocalAPIService(store: store, runtime: runtime) } catch {
                logger.error("Local API unavailable: \(String(describing: error), privacy: .public)")
                return nil
            }
        }
        return nil
    }
}
